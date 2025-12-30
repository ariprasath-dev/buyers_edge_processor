require 'csv'
require 'caxlsx'
require 'set'

class JournalEntryProcessorService
  SERVICE_CHARGE_KEYWORDS = [
    'SERVICE CHARGE', 'SERVICE FEE', 'SERV CHARGE', 'SERV FEE',
    'SERVICE SALES', 'SERVICE-CHARGE', 'SERVICECHARGE'
  ].freeze

  attr_reader :input_path, :output_path, :data

  def initialize(input_path, output_path)
    @input_path = input_path
    @output_path = output_path
    @data = []
    @headers = nil
    @residual_map = {}
    @units_written_total_adjusted = Set.new
  end

  def process
  load_data
  prepare_columns
  mark_service_charges
  calculate_residuals
  apply_adjustments
  calculate_consolidated
  generate_excel  
 
  # Calculate and return statistics
  {
    total_rows: @data.length,
    rows_adjusted: @data.count { |row| row['ADJUSTMENT_FLAG'].to_s != '' },
    units_affected: @residual_map.keys.length
  }
end

  private

  def load_data
    CSV.foreach(@input_path, headers: true, encoding: 'UTF-8') do |row|
      @headers ||= row.headers
      @data << row.to_h
    end
    
    raise 'CSV file is empty or has no data rows' if @data.empty?
    raise 'CSV must contain required columns' unless valid_columns?
  end

  def valid_columns?
    required = ['UNIT_NUMBER', 'GL_ACCOUNT', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT']
    required.all? { |col| @headers.include?(col) }
  end

  def prepare_columns
    @data.each do |row|
      # Convert numeric columns
      row['DEBIT_AMOUNT'] = to_float(row['DEBIT_AMOUNT'])
      row['CREDIT_AMOUNT'] = to_float(row['CREDIT_AMOUNT'])
      
      # Ensure string columns exist
      row['UNIT_NUMBER'] = row['UNIT_NUMBER'].to_s
      row['GL_ACCOUNT'] = row['GL_ACCOUNT'].to_s
      row['REFERENCE'] = row['REFERENCE'].to_s
      
      # Initialize new columns
      row['ADJUSTMENT_FLAG'] = ''
      row['Total Adjusted'] = nil
    end
  end

  def to_float(value)
    value.to_f rescue 0.0
  end

  def mark_service_charges
    @data.each do |row|
      row['IS_SERVICE_CHARGE'] = service_charge?(row)
    end
  end

  def service_charge?(row)
    account = row['GL_ACCOUNT'].to_s.upcase
    reference = row['REFERENCE'].to_s.upcase
    
    SERVICE_CHARGE_KEYWORDS.any? do |keyword|
      account.include?(keyword) || reference.include?(keyword)
    end
  end

  def calculate_residuals
    @data.each do |row|
      next unless row['GL_ACCOUNT'].to_s.include?('5104')
      
      unit = row['UNIT_NUMBER']
      @residual_map[unit] ||= { credits: 0.0, debits: 0.0 }
      @residual_map[unit][:credits] += row['CREDIT_AMOUNT']
      @residual_map[unit][:debits] += row['DEBIT_AMOUNT']
    end

    # Convert to net residual (Credits - Debits)
    @residual_map.transform_values! { |v| v[:credits] - v[:debits] }
  end

  def apply_adjustments
    @residual_map.each do |unit, residual_initial|
      residual = residual_initial.to_f
      next if residual <= 0  # Only process positive residuals (net credits)

      # Find eligible MF rows for this unit
      mf_rows = find_mf_rows(unit)
      next if mf_rows.empty?

      # Sort: by GL account, then by debit amount descending (largest first)
      mf_rows.sort_by! { |row, _idx| [row['GL_ACCOUNT'].to_s, -row['DEBIT_AMOUNT']] }

      # Distribute residual across MF debits
      mf_rows.each do |row, _idx|
        break if residual <= 0
        
        original_debit = row['DEBIT_AMOUNT'].to_f
        next if original_debit <= 0

        if original_debit >= residual
          # This row can absorb all remaining residual
          adjust_row(row, residual, original_debit, unit, residual_initial)
          residual = 0.0
        else
          # Zero out this row and continue to next
          adjust_row(row, original_debit, original_debit, unit, residual_initial)
          residual -= original_debit
        end
      end
    end
  end

  def find_mf_rows(unit)
    @data.each_with_index.select do |row, _idx|
      row['UNIT_NUMBER'] == unit &&
      row['GL_ACCOUNT'].to_s.start_with?('500') &&
      !row['IS_SERVICE_CHARGE'] &&
      row['DEBIT_AMOUNT'] > 0
    end
  end

  def adjust_row(row, adjustment, original, unit, residual_initial)
    new_debit = original - adjustment
    row['DEBIT_AMOUNT'] = new_debit
    row['ADJUSTMENT_FLAG'] = format('Adjusted by %.2f (was %.2f)', adjustment, original)
    
    # Write 'Total Adjusted' only once per unit (on first adjusted row)
    unless @units_written_total_adjusted.include?(unit)
      row['Total Adjusted'] = residual_initial
      @units_written_total_adjusted.add(unit)
    end
  end

  def calculate_consolidated
    @data.each do |row|
      diff = row['CREDIT_AMOUNT'] - row['DEBIT_AMOUNT']
      
      # For GL 5104: signed difference (can be negative)
      # For others: absolute value
      row['ConsolidatedCreditsDebits'] = if row['GL_ACCOUNT'].to_s.include?('5104')
                                           diff
                                         else
                                           diff.abs
                                         end
    end
  end

  def generate_excel
    Axlsx::Package.new do |p|
      wb = p.workbook
      
      create_adjusted_data_sheet(wb)
      create_summary_sheet(wb)
      
      p.serialize(@output_path)
    end
  end

  def create_adjusted_data_sheet(workbook)
    output_cols = @data.first.keys
    
    yellow_fill = workbook.styles.add_style(bg_color: 'FFFF00')
    header_style = workbook.styles.add_style(
      b: true,
      alignment: { horizontal: :center }
    )
    
    workbook.add_worksheet(name: 'AdjustedData') do |sheet|
      # Add headers
      sheet.add_row output_cols, style: header_style
      
      # Add data rows with conditional yellow highlighting
      @data.each do |row|
        row_data = output_cols.map { |col| row[col] }
        
        style = row['ADJUSTMENT_FLAG'].to_s != '' ? yellow_fill : nil
        sheet.add_row row_data, style: style
      end
      
      # Freeze top row
      freeze_top_row(sheet)
      
      # Auto-fit columns
      auto_fit_columns(sheet, output_cols, @data)
    end
  end

  def create_summary_sheet(workbook)
  # Prepare summary data
  summary_data = prepare_summary_data
  
  workbook.add_worksheet(name: 'Summary') do |sheet|
    # Header row with bold
    bold_style = workbook.styles.add_style(b: true, alignment: { horizontal: :center })
    
    sheet.add_row ['UNIT_NUMBER', 'Total_Adjusted', 'Rows_Adjusted', 'Sum_Debit_Reductions', 'Consolidated_Total'], 
                  style: bold_style
    
    # Data rows (skip the grand total for now)
    data_rows = summary_data.reject { |row| row['UNIT_NUMBER'] == 'GRAND TOTAL' }
    data_rows.each do |row|
      sheet.add_row [
        row['UNIT_NUMBER'],
        row['Total_Adjusted'],
        row['Rows_Adjusted'],
        row['Sum_Debit_Reductions'],
        row['Consolidated_Total']
      ]
    end
    
    # Add GRAND TOTAL row with bold + yellow background
    grand_total_style = workbook.styles.add_style(b: true, bg_color: 'FFFF00')
    grand_total_row = summary_data.find { |row| row['UNIT_NUMBER'] == 'GRAND TOTAL' }
    
    if grand_total_row
      sheet.add_row [
        grand_total_row['UNIT_NUMBER'],
        grand_total_row['Total_Adjusted'],
        grand_total_row['Rows_Adjusted'],
        grand_total_row['Sum_Debit_Reductions'],
        grand_total_row['Consolidated_Total']
      ], style: grand_total_style
    end
    
    # Add blank rows for separation
    sheet.add_row []
    sheet.add_row []
    
    # Add logic explanation
    explanation_rows = [
      ['', '', '', '', '', '', 'MF Deduction Logic Recap:'],
      ['', '', '', '', '', '', '• Service charges are excluded from deductions.'],
      ['', '', '', '', '', '', '• GL 5104 residual = Credits − Debits (signed). When residual > 0 (net credit), subtract from GL 500x MF debits.'],
      ['', '', '', '', '', '', '• Residual is distributed across the least number of GL 500x debit rows (largest first).'],
      ['', '', '', '', '', '', '• \'Total Adjusted\' shows the net residual applied for the unit (written once on the first adjusted row).'],
      ['', '', '', '', '', '', '• \'ConsolidatedCreditsDebits\' is recalculated after adjustments:'],
      ['', '', '', '', '', '', '  − For non-5104 rows: ABS(Credit − adjusted Debit).'],
      ['', '', '', '', '', '', '  − For 5104 rows: signed (Credit − adjusted Debit) (negative allowed).'],
      ['', '', '', '', '', '', '• Adjusted rows are highlighted in yellow on the AdjustedData sheet; header is purple.']
    ]
    
    explanation_rows.each do |row|
      sheet.add_row row
    end    
    # Set column widths
    sheet.column_widths 15, 18, 18, 22, 20, 5, 80
  end
end

  def prepare_summary_data
    # Calculate original debits and reductions
    @data.each do |row|
      row['_ORIGINAL_DEBIT_'] = extract_original_debit(
        row['ADJUSTMENT_FLAG'],
        row['DEBIT_AMOUNT']
      )
      row['_DEBIT_REDUCTION_'] = [
        row['_ORIGINAL_DEBIT_'] - row['DEBIT_AMOUNT'],
        0
      ].max
    end

    # Group by unit
    per_unit = Hash.new do |h, unit|
      h[unit] = {
        'UNIT_NUMBER' => unit,
        'Total_Adjusted' => 0.0,
        'Rows_Adjusted' => 0,
        'Sum_Debit_Reductions' => 0.0,
        'Consolidated_Total' => 0.0
      }
    end

    @data.each do |row|
      unit = row['UNIT_NUMBER']
      per_unit[unit]['Total_Adjusted'] += row['Total Adjusted'].to_f
      per_unit[unit]['Rows_Adjusted'] += 1 if row['ADJUSTMENT_FLAG'].to_s != ''
      per_unit[unit]['Sum_Debit_Reductions'] += row['_DEBIT_REDUCTION_']
      per_unit[unit]['Consolidated_Total'] += row['ConsolidatedCreditsDebits']
    end

    # Sort by unit number and add grand total
    sorted_data = per_unit.values.sort_by { |r| r['UNIT_NUMBER'] }
    sorted_data << calculate_grand_total(sorted_data)
    
    sorted_data
  end

  def extract_original_debit(flag, current_debit)
    return current_debit unless flag.to_s.include?('was')
    
    flag.split('was').last.strip.gsub(')', '').to_f
  rescue
    current_debit
  end

  def calculate_grand_total(summary_data)
    {
      'UNIT_NUMBER' => 'GRAND TOTAL',
      'Total_Adjusted' => summary_data.sum { |r| r['Total_Adjusted'] },
      'Rows_Adjusted' => summary_data.sum { |r| r['Rows_Adjusted'] },
      'Sum_Debit_Reductions' => summary_data.sum { |r| r['Sum_Debit_Reductions'] },
      'Consolidated_Total' => summary_data.sum { |r| r['Consolidated_Total'] }
    }
  end

  def add_recap_section(sheet, data_rows, bold_style)
    recap_row_start = data_rows + 3
    
    recap_lines = [
      "MF Deduction Logic Recap:",
      "• Service charges are excluded from deductions.",
      "• GL 5104 residual = Credits − Debits (signed). When residual > 0 (net credit), subtract it from MF debits in GL 500x.",
      "• Residual is distributed across the least number of GL 500x debit rows (largest first) until fully applied.",
      "• 'Total Adjusted' shows the net residual applied for the unit (written once on the first adjusted row).",
      "• 'ConsolidatedCreditsDebits' is recalculated after adjustments:",
      "    – For non‑5104 rows: ABS(Credit − adjusted Debit).",
      "    – For 5104 rows: signed (Credit − adjusted Debit) (negative allowed).",
      "• Adjusted rows are highlighted in yellow on the AdjustedData sheet; header is frozen and columns auto‑fit."
    ]
    
    recap_lines.each_with_index do |line, idx|
      style = idx.zero? ? bold_style : nil
      sheet.add_row [line], style: style
    end
  end

  def freeze_top_row(sheet)
    sheet.sheet_view.pane do |pane|
      pane.top_left_cell = 'A2'
      pane.state = :frozen
      pane.y_split = 1
    end
  end

  def auto_fit_columns(sheet, columns, data)
    columns.each_with_index do |col, idx|
      max_length = [
        col.length,
        data.map { |r| r[col].to_s.length }.max || 0
      ].max
      
      sheet.column_info[idx].width = [max_length + 2, 60].min
    end
  end

  def build_result
    {
      total_rows: @data.length,
      adjusted_rows: @data.count { |r| r['ADJUSTMENT_FLAG'].to_s != '' },
      units_affected: @units_written_total_adjusted.size,
      output_file: @output_path.to_s
    }
  end
end
