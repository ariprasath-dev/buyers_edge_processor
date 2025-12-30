class JournalEntriesController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [:create]

  # GET /
  def index
    # Render upload form
  end

  # POST /journal_entries
  def create
  # Check if file parameter exists
  unless params[:file].present?
    flash[:error] = 'Please select a CSV file to upload'
    redirect_to root_path and return
  end

  uploaded_file = params[:file]

  # Validate file type
  unless uploaded_file.content_type == 'text/csv' || uploaded_file.original_filename.end_with?('.csv')
    flash[:error] = 'Please upload a valid CSV file'
    redirect_to root_path and return
  end

  begin
    # Create unique filename
    timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
    input_filename = "input_#{timestamp}.csv"
    output_filename = "Adjusted_JE_#{timestamp}.xlsx"

    # Save uploaded file to tmp/uploads
    input_path = Rails.root.join('tmp', 'uploads', input_filename)
    File.open(input_path, 'wb') do |file|
      file.write(uploaded_file.read)
    end

    # Process the file
    output_path = Rails.root.join('tmp', 'outputs', output_filename)
    processor = JournalEntryProcessorService.new(input_path.to_s, output_path.to_s)
    result = processor.process

    # Store in session
    session[:output_file] = output_filename
    session[:processing_result] = result

    # Clean up input file
    File.delete(input_path) if File.exist?(input_path)

    # Redirect to result page
    redirect_to result_journal_entries_path

  rescue StandardError => e
    Rails.logger.error "Processing error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    
    flash[:error] = "Error processing file: #{e.message}"
    redirect_to root_path
  end
end

  # GET /journal_entries/result
  def result
    unless session[:output_file]
      redirect_to root_path and return
    end

    @output_filename = session[:output_file]
    @result = session[:processing_result] || {}
  end

  # GET /journal_entries/download/:filename
    def download      
    filename = params[:filename]
    filename = "#{filename}.xlsx" unless filename.end_with?('.xlsx')
    file_path = Rails.root.join('tmp', 'outputs', filename)

    unless File.exist?(file_path)
        flash[:error] = 'File not found or has expired'
        redirect_to root_path and return
    end

    send_file file_path,
                filename: filename,
                type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                disposition: 'attachment'
    end

  private

  def save_uploaded_file(uploaded_file)
    temp_path = Rails.root.join('tmp', 'uploads', "upload_#{SecureRandom.hex(8)}.csv")
    FileUtils.mkdir_p(File.dirname(temp_path))
    
    File.open(temp_path, 'wb') do |file|
      file.write(uploaded_file.read)
    end
    
    temp_path.to_s
  end

  def generate_output_filename
    timestamp = Time.current.strftime('%Y%m%d_%H%M%S')
    "Adjusted_JE_#{timestamp}.xlsx"
  end
end
