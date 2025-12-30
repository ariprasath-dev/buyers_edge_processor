# spec/services/journal_entry_processor_service_spec.rb

require 'rails_helper'

RSpec.describe JournalEntryProcessorService, type: :service do
  let(:input_path) { Rails.root.join('spec', 'fixtures', "test_#{SecureRandom.hex(4)}.csv") }
  let(:output_path) { Rails.root.join('tmp', "test_output_#{SecureRandom.hex(4)}.xlsx") }
  let(:service) { described_class.new(input_path.to_s, output_path.to_s) }

  before do
    FileUtils.mkdir_p(Rails.root.join('tmp'))
    FileUtils.mkdir_p(Rails.root.join('spec', 'fixtures'))
  end

  after do
    File.delete(output_path) if File.exist?(output_path)
    File.delete(input_path) if File.exist?(input_path)
  end

  describe '#initialize' do
    it 'sets input and output paths' do
      expect(service.input_path).to eq(input_path.to_s)
      expect(service.output_path).to eq(output_path.to_s)
    end

    it 'initializes empty data array' do
      expect(service.data).to eq([])
    end

    it 'initializes residual map' do
      expect(service.instance_variable_get(:@residual_map)).to eq({})
    end

    it 'initializes units_written_total_adjusted set' do
      expect(service.instance_variable_get(:@units_written_total_adjusted)).to be_a(Set)
    end
  end

  describe '#process (full integration)' do
    context 'with valid CSV file' do
      before do
        create_test_csv_with_adjustments
      end

      it 'processes the file successfully' do
        result = service.process
        expect(result).to be_a(Hash)
        expect(result[:total_rows]).to be > 0
      end

      it 'returns correct statistics with symbol keys' do
        result = service.process
        expect(result).to have_key(:total_rows)
        expect(result).to have_key(:rows_adjusted)
        expect(result).to have_key(:units_affected)
      end

      it 'generates Excel file' do
        service.process
        expect(File.exist?(output_path)).to be true
      end

      it 'adjusts correct number of rows' do
        result = service.process
        expect(result[:rows_adjusted]).to eq(1)
      end

      it 'identifies correct units affected' do
        result = service.process
        expect(result[:units_affected]).to eq(1)
      end

      it 'calculates total rows correctly' do
        result = service.process
        expect(result[:total_rows]).to eq(4)
      end

      it 'executes all processing steps in order' do
        expect(service).to receive(:load_data).and_call_original
        expect(service).to receive(:prepare_columns).and_call_original
        expect(service).to receive(:mark_service_charges).and_call_original
        expect(service).to receive(:calculate_residuals).and_call_original
        expect(service).to receive(:apply_adjustments).and_call_original
        expect(service).to receive(:calculate_consolidated).and_call_original
        expect(service).to receive(:generate_excel).and_call_original
        service.process
      end
    end

    context 'with empty CSV file' do
      before do
        create_empty_csv
      end

      it 'raises error for empty file' do
        expect { service.process }.to raise_error('CSV file is empty or has no data rows')
      end
    end

    context 'with missing required columns' do
      before do
        create_csv_missing_columns
      end

      it 'raises error for missing columns' do
        expect { service.process }.to raise_error('CSV must contain required columns')
      end
    end
  end

  describe '#load_data' do
    context 'with valid CSV' do
      before do
        create_simple_csv
      end

      it 'loads data from CSV' do
        service.send(:load_data)
        expect(service.data).not_to be_empty
      end

      it 'sets headers correctly' do
        service.send(:load_data)
        expect(service.instance_variable_get(:@headers)).to include('UNIT_NUMBER', 'GL_ACCOUNT')
      end

      it 'converts CSV rows to hashes' do
        service.send(:load_data)
        expect(service.data.first).to be_a(Hash)
      end
    end

    context 'with invalid file path' do
      it 'raises error' do
        invalid_service = described_class.new('nonexistent.csv', output_path.to_s)
        expect { invalid_service.send(:load_data) }.to raise_error(Errno::ENOENT)
      end
    end
  end

  describe '#valid_columns?' do
    before do
      create_simple_csv
      service.send(:load_data)
    end

    it 'returns true for valid columns' do
      expect(service.send(:valid_columns?)).to be true
    end

    it 'returns false when missing required columns' do
      service.instance_variable_set(:@headers, ['UNIT_NUMBER'])
      expect(service.send(:valid_columns?)).to be false
    end

    it 'checks for all required columns' do
      required_cols = ['UNIT_NUMBER', 'GL_ACCOUNT', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT']
      service.instance_variable_set(:@headers, required_cols)
      expect(service.send(:valid_columns?)).to be true
    end
  end

  describe '#prepare_columns' do
    before do
      create_simple_csv
      service.send(:load_data)
    end

    it 'converts debit amounts to float' do
      service.send(:prepare_columns)
      expect(service.data.first['DEBIT_AMOUNT']).to be_a(Float)
      expect(service.data.first['DEBIT_AMOUNT']).to eq(100.0)
    end

    it 'converts credit amounts to float' do
      service.send(:prepare_columns)
      expect(service.data.first['CREDIT_AMOUNT']).to be_a(Float)
      expect(service.data.first['CREDIT_AMOUNT']).to eq(0.0)
    end

    it 'converts unit number to string' do
      service.send(:prepare_columns)
      expect(service.data.first['UNIT_NUMBER']).to be_a(String)
    end

    it 'ensures GL_ACCOUNT is string' do
      service.send(:prepare_columns)
      expect(service.data.first['GL_ACCOUNT']).to be_a(String)
    end

    it 'ensures REFERENCE is string' do
      service.send(:prepare_columns)
      expect(service.data.first['REFERENCE']).to be_a(String)
    end

    it 'initializes adjustment flag as empty' do
      service.send(:prepare_columns)
      expect(service.data.first['ADJUSTMENT_FLAG']).to eq('')
    end

    it 'initializes Total Adjusted as nil' do
      service.send(:prepare_columns)
      expect(service.data.first['Total Adjusted']).to be_nil
    end

    it 'handles invalid numeric values gracefully' do
      create_csv_with_text_in_amounts
      service.send(:load_data)
      service.send(:prepare_columns)
      expect(service.data.first['DEBIT_AMOUNT']).to be_a(Float)
    end
  end

  describe '#to_float' do
    it 'converts string to float' do
      expect(service.send(:to_float, '123.45')).to eq(123.45)
    end

    it 'converts integer to float' do
      expect(service.send(:to_float, 100)).to eq(100.0)
    end

    it 'handles nil values' do
      expect(service.send(:to_float, nil)).to eq(0.0)
    end

    it 'handles empty strings' do
      expect(service.send(:to_float, '')).to eq(0.0)
    end

    it 'handles invalid strings' do
      expect(service.send(:to_float, 'invalid')).to eq(0.0)
    end

    it 'handles strings with spaces' do
      expect(service.send(:to_float, '  123.45  ')).to eq(123.45)
    end
  end

  describe '#mark_service_charges' do
    before do
      create_csv_with_service_charges
      service.send(:load_data)
      service.send(:prepare_columns)
    end

    it 'identifies service charges by keyword in reference' do
      service.send(:mark_service_charges)
      service_charge_row = service.data.find { |r| r['REFERENCE'].to_s.upcase.include?('SERVICE CHARGE') }
      expect(service_charge_row['IS_SERVICE_CHARGE']).to be true
    end

    it 'identifies service charges by keyword in account' do
      service.send(:mark_service_charges)
      service_charge_row = service.data.find { |r| r['GL_ACCOUNT'].to_s.upcase.include?('SERVICE FEE') }
      expect(service_charge_row['IS_SERVICE_CHARGE']).to be true
    end

    it 'does not mark regular MF rows as service charges' do
      service.send(:mark_service_charges)
      regular_row = service.data.find { |r| r['REFERENCE'].to_s == 'Regular Entry' }
      expect(regular_row['IS_SERVICE_CHARGE']).to be false
    end

    it 'marks all service charge keywords' do
      service.send(:mark_service_charges)
      marked_rows = service.data.select { |r| r['IS_SERVICE_CHARGE'] }
      expect(marked_rows.count).to eq(2)
    end
  end

  describe '#service_charge?' do
    it 'detects SERVICE CHARGE in account' do
      row = {'GL_ACCOUNT' => 'SERVICE CHARGE', 'REFERENCE' => 'Normal'}
      expect(service.send(:service_charge?, row)).to be true
    end

    it 'detects SERVICE FEE in reference' do
      row = {'GL_ACCOUNT' => '5001', 'REFERENCE' => 'SERVICE FEE'}
      expect(service.send(:service_charge?, row)).to be true
    end

    it 'detects SERV CHARGE' do
      row = {'GL_ACCOUNT' => 'SERV CHARGE', 'REFERENCE' => ''}
      expect(service.send(:service_charge?, row)).to be true
    end

    it 'detects SERVICE SALES' do
      row = {'GL_ACCOUNT' => '', 'REFERENCE' => 'SERVICE SALES'}
      expect(service.send(:service_charge?, row)).to be true
    end

    it 'is case insensitive' do
      row = {'GL_ACCOUNT' => '5001', 'REFERENCE' => 'service charge'}
      expect(service.send(:service_charge?, row)).to be true
    end

    it 'does not detect regular entries' do
      row = {'GL_ACCOUNT' => '5001', 'REFERENCE' => 'Normal Entry'}
      expect(service.send(:service_charge?, row)).to be false
    end
  end

  describe '#calculate_residuals' do
    it 'calculates positive residual for unit with net credit' do
      create_test_csv_with_adjustments
      service.send(:load_data)
      service.send(:prepare_columns)
      service.send(:calculate_residuals)
      residual_map = service.instance_variable_get(:@residual_map)
      expect(residual_map['129']).to eq(26.15)
    end

    it 'handles multiple GL 5104 entries for same unit' do
      create_csv_with_only_two_5104_credits
      service.send(:load_data)
      service.send(:prepare_columns)
      service.send(:calculate_residuals)
      residual_map = service.instance_variable_get(:@residual_map)
      expect(residual_map['130']).to eq(50.0)
    end

    it 'sums credits correctly' do
      create_csv_with_only_two_5104_credits
      service.send(:load_data)
      service.send(:prepare_columns)
      service.send(:calculate_residuals)
      residual_map = service.instance_variable_get(:@residual_map)
      expect(residual_map['130']).to eq(25.0 + 25.0)
    end

    it 'subtracts debits from credits' do
      create_csv_with_5104_debits_and_credits
      service.send(:load_data)
      service.send(:prepare_columns)
      service.send(:calculate_residuals)
      residual_map = service.instance_variable_get(:@residual_map)
      expect(residual_map['135']).to eq(100.0 - 25.0)
    end

    it 'ignores non-5104 accounts' do
      create_test_csv_with_adjustments
      service.send(:load_data)
      service.send(:prepare_columns)
      service.send(:calculate_residuals)
      residual_map = service.instance_variable_get(:@residual_map)
      expect(residual_map.keys).not_to include('128')
    end

    it 'transforms hash to numeric values' do
      create_test_csv_with_adjustments
      service.send(:load_data)
      service.send(:prepare_columns)
      service.send(:calculate_residuals)
      residual_map = service.instance_variable_get(:@residual_map)
      expect(residual_map['129']).to be_a(Numeric)
    end

    it 'only processes rows with 5104 in GL_ACCOUNT' do
      create_test_csv_with_adjustments
      service.send(:load_data)
      service.send(:prepare_columns)
      service.send(:calculate_residuals)
      residual_map = service.instance_variable_get(:@residual_map)
      expect(residual_map.size).to eq(1)
    end
  end

  describe '#apply_adjustments' do
    before do
      create_test_csv_with_adjustments
      service.send(:load_data)
      service.send(:prepare_columns)
      service.send(:mark_service_charges)
      service.send(:calculate_residuals)
    end

    it 'adjusts eligible rows' do
      service.send(:apply_adjustments)
      adjusted_row = service.data.find { |r| r['ADJUSTMENT_FLAG'] != '' }
      expect(adjusted_row).not_to be_nil
    end

    it 'reduces debit amount by residual' do
      service.send(:apply_adjustments)
      adjusted_row = service.data.find { |r| r['ADJUSTMENT_FLAG'] != '' }
      expect(adjusted_row['DEBIT_AMOUNT']).to eq(825.85)
    end

    it 'sets adjustment flag with correct message' do
      service.send(:apply_adjustments)
      adjusted_row = service.data.find { |r| r['ADJUSTMENT_FLAG'] != '' }
      expect(adjusted_row['ADJUSTMENT_FLAG']).to include('Adjusted by 26.15')
      expect(adjusted_row['ADJUSTMENT_FLAG']).to include('was 852.00')
    end

    it 'sets total adjusted for unit' do
      service.send(:apply_adjustments)
      adjusted_row = service.data.find { |r| r['ADJUSTMENT_FLAG'] != '' }
      expect(adjusted_row['Total Adjusted']).to eq(26.15)
    end

    it 'skips units with zero or negative residuals' do
      residual_map = service.instance_variable_get(:@residual_map)
      residual_map['999'] = -10.0
      service.send(:apply_adjustments)
      unit_999_adjusted = service.data.select { |r| r['UNIT_NUMBER'] == '999' && r['ADJUSTMENT_FLAG'] != '' }
      expect(unit_999_adjusted).to be_empty
    end

    it 'handles large residuals that require multiple rows' do
      large_input = Rails.root.join('spec', 'fixtures', "test_large_#{SecureRandom.hex(4)}.csv")
      large_output = Rails.root.join('tmp', "test_large_#{SecureRandom.hex(4)}.xlsx")
      
      CSV.open(large_input, 'w') do |csv|
        csv << ['UNIT_NUMBER', 'GL_ACCOUNT', 'TRANSACTION', 'SOURCE', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT', 'REFERENCE']
        csv << ['131', '5104', 'INVENTORY', 'INV', '0', '500.00', 'Large Credit']
        csv << ['131', '5001', 'MF COST', 'MFG', '200.00', '0', 'Debit 1']
        csv << ['131', '5002', 'MF LABOR', 'MFG', '150.00', '0', 'Debit 2']
        csv << ['131', '5003', 'MF OVERHEAD', 'MFG', '100.00', '0', 'Debit 3']
      end
      
      large_service = described_class.new(large_input.to_s, large_output.to_s)
      result = large_service.process
      
      expect(result[:rows_adjusted]).to be >= 2
      
      File.delete(large_input) if File.exist?(large_input)
      File.delete(large_output) if File.exist?(large_output)
    end

    it 'processes each unit independently' do
      service.send(:apply_adjustments)
      units_set = service.instance_variable_get(:@units_written_total_adjusted)
      expect(units_set).to be_a(Set)
      expect(units_set).to include('129')
    end
  end

  describe '#find_mf_rows' do
    before do
      create_test_csv_with_adjustments
      service.send(:load_data)
      service.send(:prepare_columns)
      service.send(:mark_service_charges)
    end

    it 'returns MF rows for given unit' do
      mf_rows = service.send(:find_mf_rows, '129')
      expect(mf_rows).to be_an(Array)
      expect(mf_rows).not_to be_empty
    end

    it 'returns array of [row, index] pairs' do
      mf_rows = service.send(:find_mf_rows, '129')
      expect(mf_rows.first).to be_an(Array)
      expect(mf_rows.first.length).to eq(2)
    end

    it 'excludes service charges' do
      mf_rows = service.send(:find_mf_rows, '129')
      service_charge_rows = mf_rows.select { |row, _| row['IS_SERVICE_CHARGE'] == true }
      expect(service_charge_rows).to be_empty
    end

    it 'only includes rows with positive debits' do
      mf_rows = service.send(:find_mf_rows, '129')
      mf_rows.each do |row, _idx|
        expect(row['DEBIT_AMOUNT']).to be > 0
      end
    end

    it 'only includes GL 500x accounts' do
      mf_rows = service.send(:find_mf_rows, '129')
      mf_rows.each do |row, _idx|
        expect(row['GL_ACCOUNT'].to_s).to start_with('500')
      end
    end

    it 'only includes rows for specified unit' do
      mf_rows = service.send(:find_mf_rows, '129')
      mf_rows.each do |row, _idx|
        expect(row['UNIT_NUMBER']).to eq('129')
      end
    end
  end

  describe '#adjust_row' do
    before do
      create_simple_csv
      service.send(:load_data)
      service.send(:prepare_columns)
    end

    it 'updates debit amount' do
      row = service.data.first
      original = row['DEBIT_AMOUNT']
      service.send(:adjust_row, row, 10.0, original, '128', 10.0)
      expect(row['DEBIT_AMOUNT']).to eq(original - 10.0)
    end

    it 'sets adjustment flag with correct format' do
      row = service.data.first
      original = row['DEBIT_AMOUNT']
      service.send(:adjust_row, row, 10.0, original, '128', 10.0)
      expect(row['ADJUSTMENT_FLAG']).to match(/Adjusted by \d+\.\d+ \(was \d+\.\d+\)/)
    end

    it 'sets Total Adjusted once per unit' do
      row = service.data.first
      original = row['DEBIT_AMOUNT']
      service.send(:adjust_row, row, 10.0, original, '128', 10.0)
      expect(row['Total Adjusted']).to eq(10.0)
    end

    it 'tracks which units have been written' do
      row = service.data.first
      original = row['DEBIT_AMOUNT']
      service.send(:adjust_row, row, 10.0, original, '128', 10.0)
      units_set = service.instance_variable_get(:@units_written_total_adjusted)
      expect(units_set).to include('128')
    end
  end

  describe '#calculate_consolidated' do
    before do
      create_test_csv_with_adjustments
      service.send(:load_data)
      service.send(:prepare_columns)
      service.send(:mark_service_charges)
      service.send(:calculate_residuals)
      service.send(:apply_adjustments)
    end

    it 'calculates consolidated values for all rows' do
      service.send(:calculate_consolidated)
      service.data.each do |row|
        expect(row['ConsolidatedCreditsDebits']).not_to be_nil
      end
    end

    it 'uses signed value for GL 5104' do
      service.send(:calculate_consolidated)
      gl_5104_row = service.data.find { |r| r['GL_ACCOUNT'].include?('5104') }
      consolidated = gl_5104_row['ConsolidatedCreditsDebits']
      expect(consolidated).to be > 0
    end

    it 'uses absolute value for non-5104 accounts' do
      service.send(:calculate_consolidated)
      non_5104_row = service.data.find { |r| !r['GL_ACCOUNT'].include?('5104') }
      consolidated = non_5104_row['ConsolidatedCreditsDebits']
      expect(consolidated).to be >= 0
    end

    it 'calculates credit minus debit' do
      service.send(:calculate_consolidated)
      row = service.data.first
      expected = row['CREDIT_AMOUNT'] - row['DEBIT_AMOUNT']
      if row['GL_ACCOUNT'].include?('5104')
        expect(row['ConsolidatedCreditsDebits']).to eq(expected)
      else
        expect(row['ConsolidatedCreditsDebits']).to eq(expected.abs)
      end
    end
  end

  describe '#generate_excel' do
    before do
      create_test_csv_with_adjustments
      service.send(:load_data)
      service.send(:prepare_columns)
      service.send(:mark_service_charges)
      service.send(:calculate_residuals)
      service.send(:apply_adjustments)
      service.send(:calculate_consolidated)
    end

    it 'creates Excel file' do
      service.send(:generate_excel)
      expect(File.exist?(output_path)).to be true
    end

    it 'creates file with .xlsx extension' do
      service.send(:generate_excel)
      expect(output_path.to_s).to end_with('.xlsx')
    end

    it 'generates valid Excel workbook' do
      service.send(:generate_excel)
      expect(File.size(output_path)).to be > 0
    end

    it 'calls create_adjusted_data_sheet' do
      allow(service).to receive(:create_adjusted_data_sheet)
      service.send(:generate_excel)
      expect(service).to have_received(:create_adjusted_data_sheet)
    end

    it 'calls create_summary_sheet' do
      allow(service).to receive(:create_summary_sheet)
      service.send(:generate_excel)
      expect(service).to have_received(:create_summary_sheet)
    end
  end

  describe '#prepare_summary_data' do
    before do
      create_test_csv_with_adjustments
      service.send(:load_data)
      service.send(:prepare_columns)
      service.send(:mark_service_charges)
      service.send(:calculate_residuals)
      service.send(:apply_adjustments)
      service.send(:calculate_consolidated)
    end

    it 'returns array of summary data' do
      summary = service.send(:prepare_summary_data)
      expect(summary).to be_an(Array)
    end

    it 'includes GRAND TOTAL row' do
      summary = service.send(:prepare_summary_data)
      grand_total = summary.find { |r| r['UNIT_NUMBER'] == 'GRAND TOTAL' }
      expect(grand_total).not_to be_nil
    end

    it 'calculates totals correctly' do
      summary = service.send(:prepare_summary_data)
      grand_total = summary.find { |r| r['UNIT_NUMBER'] == 'GRAND TOTAL' }
      expect(grand_total['Rows_Adjusted']).to be >= 0
      expect(grand_total['Total_Adjusted']).to be_a(Numeric)
    end

    it 'groups by unit number' do
      summary = service.send(:prepare_summary_data)
      unit_numbers = summary.map { |r| r['UNIT_NUMBER'] }.reject { |u| u == 'GRAND TOTAL' }
      expect(unit_numbers).to include('129', '128')
    end

    it 'adds _ORIGINAL_DEBIT_ to data rows' do
      service.send(:prepare_summary_data)
      expect(service.data.first).to have_key('_ORIGINAL_DEBIT_')
    end

    it 'adds _DEBIT_REDUCTION_ to data rows' do
      service.send(:prepare_summary_data)
      expect(service.data.first).to have_key('_DEBIT_REDUCTION_')
    end
  end

  describe '#extract_original_debit' do
    it 'extracts original value from adjustment flag' do
      result = service.send(:extract_original_debit, 'Adjusted by 26.15 (was 852.00)', 825.85)
      expect(result).to eq(852.00)
    end

    it 'returns current debit if no flag' do
      result = service.send(:extract_original_debit, '', 100.0)
      expect(result).to eq(100.0)
    end

    it 'handles malformed flags gracefully' do
      result = service.send(:extract_original_debit, 'Invalid flag', 100.0)
      expect(result).to eq(100.0)
    end

    it 'parses was value correctly' do
      result = service.send(:extract_original_debit, 'Adjusted by 50.00 (was 1234.56)', 1184.56)
      expect(result).to eq(1234.56)
    end
  end

  describe '#calculate_grand_total' do
    it 'sums Total_Adjusted from all units' do
      summary_data = [
        {'UNIT_NUMBER' => '1', 'Total_Adjusted' => 10.0, 'Rows_Adjusted' => 1, 'Sum_Debit_Reductions' => 10.0, 'Consolidated_Total' => 100.0},
        {'UNIT_NUMBER' => '2', 'Total_Adjusted' => 20.0, 'Rows_Adjusted' => 2, 'Sum_Debit_Reductions' => 20.0, 'Consolidated_Total' => 200.0}
      ]
      result = service.send(:calculate_grand_total, summary_data)
      expect(result['Total_Adjusted']).to eq(30.0)
    end

    it 'sums Rows_Adjusted from all units' do
      summary_data = [
        {'UNIT_NUMBER' => '1', 'Total_Adjusted' => 10.0, 'Rows_Adjusted' => 1, 'Sum_Debit_Reductions' => 10.0, 'Consolidated_Total' => 100.0},
        {'UNIT_NUMBER' => '2', 'Total_Adjusted' => 20.0, 'Rows_Adjusted' => 2, 'Sum_Debit_Reductions' => 20.0, 'Consolidated_Total' => 200.0}
      ]
      result = service.send(:calculate_grand_total, summary_data)
      expect(result['Rows_Adjusted']).to eq(3)
    end

    it 'labels row as GRAND TOTAL' do
      summary_data = []
      result = service.send(:calculate_grand_total, summary_data)
      expect(result['UNIT_NUMBER']).to eq('GRAND TOTAL')
    end
  end

  describe 'edge cases' do
    it 'handles unit with no eligible debit rows' do
      create_csv_with_credit_but_no_debits
      result = service.process
      expect(result[:rows_adjusted]).to eq(0)
    end

    it 'handles large file' do
      create_large_csv(100)
      result = service.process
      expect(result[:total_rows]).to eq(100)
    end

    it 'handles file with only non-5104 accounts' do
      create_csv_with_no_5104
      result = service.process
      expect(result[:rows_adjusted]).to eq(0)
      expect(result[:units_affected]).to eq(0)
    end

    it 'handles file with multiple units' do
      create_csv_with_multiple_units
      result = service.process
      expect(result[:total_rows]).to be > 0
    end
  end

  # Helper methods to create test CSV files
  def create_simple_csv
    CSV.open(input_path, 'w') do |csv|
      csv << ['UNIT_NUMBER', 'GL_ACCOUNT', 'TRANSACTION', 'SOURCE', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT', 'REFERENCE']
      csv << ['128', '5001', 'MF COST', 'MFG', '100.00', '0', 'Test Entry']
    end
  end

  def create_test_csv_with_adjustments
    CSV.open(input_path, 'w') do |csv|
      csv << ['UNIT_NUMBER', 'GL_ACCOUNT', 'TRANSACTION', 'SOURCE', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT', 'REFERENCE']
      csv << ['129', '5104', 'INVENTORY', 'INV', '0', '26.15', 'Factory Credit']
      csv << ['129', '5001', 'MF COST', 'MFG', '852.00', '0', 'Manufacturing']
      csv << ['129', '5002', 'MF LABOR', 'MFG', '450.00', '0', 'Labor']
      csv << ['128', '5001', 'MF COST', 'MFG', '200.00', '0', 'No Credit Unit']
    end
  end

  def create_empty_csv
    CSV.open(input_path, 'w') do |csv|
      csv << ['UNIT_NUMBER', 'GL_ACCOUNT', 'TRANSACTION', 'SOURCE', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT', 'REFERENCE']
    end
  end

  def create_csv_missing_columns
    CSV.open(input_path, 'w') do |csv|
      csv << ['UNIT_NUMBER', 'GL_ACCOUNT']
      csv << ['129', '5001']
    end
  end

  def create_csv_with_service_charges
    CSV.open(input_path, 'w') do |csv|
      csv << ['UNIT_NUMBER', 'GL_ACCOUNT', 'TRANSACTION', 'SOURCE', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT', 'REFERENCE']
      csv << ['129', '5001', 'MF COST', 'MFG', '100.00', '0', 'SERVICE CHARGE']
      csv << ['129', '5001 SERVICE FEE', 'MF COST', 'MFG', '50.00', '0', 'Fee']
      csv << ['129', '5002', 'MF LABOR', 'MFG', '200.00', '0', 'Regular Entry']
    end
  end

  def create_csv_with_text_in_amounts
    CSV.open(input_path, 'w') do |csv|
      csv << ['UNIT_NUMBER', 'GL_ACCOUNT', 'TRANSACTION', 'SOURCE', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT', 'REFERENCE']
      csv << ['129', '5001', 'MF COST', 'MFG', 'text', 'bad', 'Test']
    end
  end

  def create_csv_with_only_two_5104_credits
    CSV.open(input_path, 'w') do |csv|
      csv << ['UNIT_NUMBER', 'GL_ACCOUNT', 'TRANSACTION', 'SOURCE', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT', 'REFERENCE']
      csv << ['130', '5104', 'INVENTORY', 'INV', '0', '25.00', 'Credit 1']
      csv << ['130', '5104', 'INVENTORY', 'INV', '0', '25.00', 'Credit 2']
      csv << ['130', '5001', 'MF COST', 'MFG', '100.00', '0', 'Manufacturing']
    end
  end

  def create_csv_with_5104_debits_and_credits
    CSV.open(input_path, 'w') do |csv|
      csv << ['UNIT_NUMBER', 'GL_ACCOUNT', 'TRANSACTION', 'SOURCE', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT', 'REFERENCE']
      csv << ['135', '5104', 'INVENTORY', 'INV', '25.00', '100.00', 'Net Credit']
      csv << ['135', '5001', 'MF COST', 'MFG', '200.00', '0', 'Manufacturing']
    end
  end

  def create_csv_with_credit_but_no_debits
    CSV.open(input_path, 'w') do |csv|
      csv << ['UNIT_NUMBER', 'GL_ACCOUNT', 'TRANSACTION', 'SOURCE', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT', 'REFERENCE']
      csv << ['132', '5104', 'INVENTORY', 'INV', '0', '100.00', 'Credit']
      csv << ['132', '2200', 'SALES TAX', 'CRJ', '50.00', '0', 'Not MF Account']
    end
  end

  def create_large_csv(row_count)
    CSV.open(input_path, 'w') do |csv|
      csv << ['UNIT_NUMBER', 'GL_ACCOUNT', 'TRANSACTION', 'SOURCE', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT', 'REFERENCE']
      row_count.times do |i|
        csv << ["#{200 + (i % 10)}", '5001', 'MF COST', 'MFG', '100.00', '0', "Entry #{i}"]
      end
    end
  end

  def create_csv_with_no_5104
    CSV.open(input_path, 'w') do |csv|
      csv << ['UNIT_NUMBER', 'GL_ACCOUNT', 'TRANSACTION', 'SOURCE', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT', 'REFERENCE']
      csv << ['133', '5001', 'MF COST', 'MFG', '100.00', '0', 'Cost']
      csv << ['133', '5002', 'MF LABOR', 'MFG', '200.00', '0', 'Labor']
    end
  end

  def create_csv_with_multiple_units
    CSV.open(input_path, 'w') do |csv|
      csv << ['UNIT_NUMBER', 'GL_ACCOUNT', 'TRANSACTION', 'SOURCE', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT', 'REFERENCE']
      csv << ['140', '5104', 'INVENTORY', 'INV', '0', '10.00', 'Credit']
      csv << ['140', '5001', 'MF COST', 'MFG', '100.00', '0', 'Cost']
      csv << ['141', '5104', 'INVENTORY', 'INV', '0', '20.00', 'Credit']
      csv << ['141', '5001', 'MF COST', 'MFG', '200.00', '0', 'Cost']
    end
  end
end