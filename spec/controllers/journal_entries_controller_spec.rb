# spec/controllers/journal_entries_controller_spec.rb

require 'rails_helper'

RSpec.describe JournalEntriesController, type: :controller do
  before do
    FileUtils.mkdir_p(Rails.root.join('tmp/uploads'))
    FileUtils.mkdir_p(Rails.root.join('tmp/outputs'))
    FileUtils.mkdir_p(Rails.root.join('spec/fixtures/files'))
    create_test_csv_fixture
  end

  after do
    Dir.glob(Rails.root.join('tmp/uploads/*')).each { |f| File.delete(f) if File.file?(f) }
    Dir.glob(Rails.root.join('tmp/outputs/*')).each { |f| File.delete(f) if File.file?(f) }
  end

  describe 'GET #index' do
    it 'returns http success' do
      get :index
      expect(response).to have_http_status(:success)
    end

    it 'responds with HTML' do
      get :index
      expect(response.content_type).to include('text/html')
    end
  end

  describe 'POST #create' do
    context 'with valid CSV file' do
      let(:valid_csv_file) do
        fixture_file_upload('test_journal_entry.csv', 'text/csv')
      end

      it 'redirects after processing' do
        post :create, params: { file: valid_csv_file }
        expect(response).to have_http_status(:redirect)
      end

      it 'redirects to result page' do
        post :create, params: { file: valid_csv_file }
        expect(response).to redirect_to(result_journal_entries_path)
      end

      it 'stores output filename in session' do
        post :create, params: { file: valid_csv_file }
        expect(session[:output_file]).not_to be_nil
        expect(session[:output_file]).to include('Adjusted_JE_')
      end

      it 'stores processing result in session' do
        post :create, params: { file: valid_csv_file }
        expect(session[:processing_result]).to be_a(Hash)
      end

      it 'processes the file with symbol keys' do
        post :create, params: { file: valid_csv_file }
        result = session[:processing_result]
        expect(result).to have_key(:total_rows)
        expect(result).to have_key(:rows_adjusted)
        expect(result).to have_key(:units_affected)
      end

      it 'calculates correct total rows' do
        post :create, params: { file: valid_csv_file }
        expect(session[:processing_result][:total_rows]).to eq(3)
      end

      it 'deletes uploaded temp file after processing' do
        post :create, params: { file: valid_csv_file }
        temp_files = Dir.glob(Rails.root.join('tmp/uploads/input_*'))
        expect(temp_files).to be_empty
      end
    end

    context 'without file' do
      it 'redirects to root path' do
        post :create, params: {}
        expect(response).to redirect_to(root_path)
      end

      it 'sets error flash message' do
        post :create, params: {}
        expect(flash[:error]).to eq('Please select a CSV file to upload')
      end

      it 'does not create session data' do
        post :create, params: {}
        expect(session[:output_file]).to be_nil
      end
    end

    context 'with invalid file type' do
      let(:invalid_file) do
        fixture_file_upload('test.txt', 'text/plain')
      end

      it 'redirects to root path' do
        post :create, params: { file: invalid_file }
        expect(response).to redirect_to(root_path)
      end

      it 'sets error flash message' do
        post :create, params: { file: invalid_file }
        expect(flash[:error]).to eq('Please upload a valid CSV file')
      end

      it 'does not process the file' do
        post :create, params: { file: invalid_file }
        expect(session[:processing_result]).to be_nil
      end
    end

    context 'when processing fails' do
      let(:valid_csv_file) do
        fixture_file_upload('test_journal_entry.csv', 'text/csv')
      end

      before do
        allow_any_instance_of(JournalEntryProcessorService).to receive(:process).and_raise(StandardError.new('Processing error'))
      end

      it 'redirects to root path' do
        post :create, params: { file: valid_csv_file }
        expect(response).to redirect_to(root_path)
      end

      it 'sets error flash message' do
        post :create, params: { file: valid_csv_file }
        expect(flash[:error]).to include('Error processing file')
      end

      it 'logs the error' do
        expect(Rails.logger).to receive(:error).at_least(:once)
        post :create, params: { file: valid_csv_file }
      end

      it 'does not create session data' do
        post :create, params: { file: valid_csv_file }
        expect(session[:processing_result]).to be_nil
      end
    end
  end

  describe 'GET #result' do
    context 'with valid session data' do
      before do
        session[:output_file] = 'test_output.xlsx'
        session[:processing_result] = {
          total_rows: 100,
          rows_adjusted: 10,
          units_affected: 5
        }
      end

      it 'returns http success' do
        get :result
        expect(response).to have_http_status(:success)
      end

      it 'stores output filename in instance variable' do
        get :result
        expect(controller.instance_variable_get(:@output_filename)).to eq('test_output.xlsx')
      end

      it 'stores result in instance variable' do
        get :result
        result = controller.instance_variable_get(:@result)
        expect(result).to be_a(Hash)
      end

      it 'has correct result data' do
        get :result
        result = controller.instance_variable_get(:@result)
        expect(result[:total_rows]).to eq(100)
        expect(result[:rows_adjusted]).to eq(10)
        expect(result[:units_affected]).to eq(5)
      end
    end

    context 'without session data' do
      it 'redirects to root path' do
        get :result
        expect(response).to redirect_to(root_path)
      end

      it 'does not set instance variables' do
        get :result
        expect(controller.instance_variable_get(:@output_filename)).to be_nil
      end
    end
  end

  describe 'GET #download' do
    let(:test_filename) { 'Adjusted_JE_test.xlsx' }
    let(:test_filepath) { Rails.root.join('tmp/outputs', test_filename) }

    before do
      FileUtils.touch(test_filepath)
    end

    after do
      File.delete(test_filepath) if File.exist?(test_filepath)
    end

    context 'with valid filename' do
      it 'sends the file' do
        get :download, params: { filename: 'Adjusted_JE_test' }
        expect(response).to have_http_status(:success)
      end

      it 'sets correct content type' do
        get :download, params: { filename: 'Adjusted_JE_test' }
        expect(response.content_type).to eq('application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')
      end

      it 'sets correct disposition' do
        get :download, params: { filename: 'Adjusted_JE_test' }
        expect(response.headers['Content-Disposition']).to include('attachment')
      end

      it 'includes filename in disposition' do
        get :download, params: { filename: 'Adjusted_JE_test' }
        expect(response.headers['Content-Disposition']).to include('Adjusted_JE_test.xlsx')
      end
    end

    context 'with invalid filename' do
      it 'redirects with error' do
        get :download, params: { filename: 'nonexistent' }
        expect(response).to have_http_status(:redirect)
        expect(flash[:error]).to include('File not found')
      end
    end

    context 'with path traversal attempt' do
      it 'does not find file outside directory' do
        get :download, params: { filename: '../../../etc/passwd' }
        expect(response).to have_http_status(:redirect)
        expect(flash[:error]).to include('File not found')
      end
    end

    context 'with filename without extension' do
      it 'automatically adds .xlsx extension' do
        get :download, params: { filename: 'Adjusted_JE_test' }
        expect(response).to have_http_status(:success)
      end
    end
  end

  # Helper method to create test CSV fixture
  def create_test_csv_fixture
    fixture_path = Rails.root.join('spec/fixtures/files/test_journal_entry.csv')
    
    CSV.open(fixture_path, 'w') do |csv|
      csv << ['UNIT_NUMBER', 'GL_ACCOUNT', 'TRANSACTION', 'SOURCE', 'DEBIT_AMOUNT', 'CREDIT_AMOUNT', 'REFERENCE']
      csv << ['129', '5104', 'INVENTORY', 'INV', '0', '26.15', 'Factory Credit']
      csv << ['129', '5001', 'MF COST', 'MFG', '852.00', '0', 'Manufacturing']
      csv << ['129', '5002', 'MF LABOR', 'MFG', '450.00', '0', 'Labor']
    end

    # Create dummy text file for invalid file type test
    txt_path = Rails.root.join('spec/fixtures/files/test.txt')
    File.write(txt_path, 'This is a text file')
  end
end