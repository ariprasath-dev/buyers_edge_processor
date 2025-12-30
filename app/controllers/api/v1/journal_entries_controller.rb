module Api
  module V1
    class JournalEntriesController < ApplicationController
      skip_before_action :verify_authenticity_token

      # POST /api/v1/journal_entries
      def create
        unless params[:file].present?
          render json: { error: 'No file uploaded' }, status: :bad_request
          return
        end

        uploaded_file = params[:file]

        begin
          # Save uploaded file
          temp_input_path = save_uploaded_file(uploaded_file)

          # Generate output
          output_filename = generate_output_filename
          output_path = Rails.root.join('tmp', 'outputs', output_filename)

          # Process
          processor = JournalEntryProcessorService.new(temp_input_path, output_path)
          result = processor.process

          render json: {
            success: true,
            message: 'File processed successfully',
            download_url: api_v1_journal_entries_download_url(filename: output_filename),
            stats: result
          }, status: :ok

        rescue StandardError => e
          Rails.logger.error("API processing error: #{e.message}")
          render json: { error: e.message }, status: :internal_server_error

        ensure
          File.delete(temp_input_path) if temp_input_path && File.exist?(temp_input_path)
        end
      end

      # GET /api/v1/journal_entries/download/:filename
      def download
        filename = params[:filename]
        file_path = Rails.root.join('tmp', 'outputs', filename)

        unless File.exist?(file_path)
          render json: { error: 'File not found' }, status: :not_found
          return
        end

        send_file file_path,
                  filename: filename,
                  type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                  disposition: 'attachment'
      end

      private

      def save_uploaded_file(uploaded_file)
        temp_path = Rails.root.join('tmp', 'uploads', "api_upload_#{SecureRandom.hex(8)}.csv")
        FileUtils.mkdir_p(File.dirname(temp_path))
        
        File.open(temp_path, 'wb') do |file|
          file.write(uploaded_file.read)
        end
        
        temp_path.to_s
      end

      def generate_output_filename
        timestamp = Time.current.strftime('%Y%m%d_%H%M%S')
        "Adjusted_JE_API_#{timestamp}.xlsx"
      end
    end
  end
end
