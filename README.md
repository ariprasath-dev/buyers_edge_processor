# Buyer's Edge JE

Automates the distribution of GL 5104 supplier credits across manufacturing cost entries.

## What It Does

1. Upload CSV file with journal entries
2. Calculates GL 5104 credit residuals per unit
3. Distributes credits to manufacturing debits (largest first)
4. Downloads Excel file with adjustments highlighted

## Tech Stack

- Ruby 3.3.0
- Rails 7.1.5
- Caxlsx (Excel generation)
- No database (file-based processing)

## Dependencies

### Required Gems

Add these to your `Gemfile`:

```ruby
# Core
gem 'rails', '~> 7.1.5'
gem 'puma', '>= 5.0'

# Excel Generation
gem 'caxlsx'

# CSV Processing
gem 'csv'

# Testing & Development
group :development, :test do
  gem 'rspec-rails', '~> 6.0'
  gem 'debug', platforms: %i[ mri windows ]
end

group :test do
  gem 'simplecov', require: false
  gem 'rails-controller-testing'
  gem 'timecop'
end
```

## Installation

```bash
# 1. Install dependencies
bundle install

# 2. Start server
rails server

# 3. Visit http://localhost:3000
```

## Usage

### Web Interface

1. Navigate to `http://localhost:3000`
2. Upload CSV with these required columns:
   - UNIT_NUMBER
   - GL_ACCOUNT
   - DEBIT_AMOUNT
   - CREDIT_AMOUNT
   - TRANSACTION (optional)
   - SOURCE (optional)
   - REFERENCE (optional)

3. Click "Process File"
4. Download Excel output with:
   - Yellow highlighting on adjusted rows
   - Summary sheet with totals

### API Endpoints

**Note:** Currently, this application has a **web interface only**. API endpoints are not implemented yet but can be added if needed for programmatic access.


#### Why No API Currently?

This tool is designed for:
-  **Direct user interaction** (upload, review, download)
- **Visual feedback** (progress indicators, summary display)
- **Immediate results** (synchronous processing)


## Available Routes

### Web Routes

```ruby
# Home page (upload form)
GET /

# Process uploaded file
POST /journal_entries

# View results
GET /journal_entries/result

# Download processed file
GET /journal_entries/download/:filename

# Help page
GET /help
```

### Route Details

| Method | Path | Purpose | Parameters |
|--------|------|---------|-----------|
| GET | `/` | Upload form | None |
| POST | `/journal_entries` | Process CSV | `file` (multipart) |
| GET | `/journal_entries/result` | Show results | None (uses session) |
| GET | `/journal_entries/download/:filename` | Download Excel | `filename` (string) |
| GET | `/help` | User guide | None |

## Business Logic

```
For each unit:
  Residual = GL_5104_Credits - GL_5104_Debits
  
If residual > 0:
  Apply to largest MF debit first (GL 500x)
  Exclude service charges
```

### Processing Flow

```
1. Upload CSV file
   ↓
2. Validate format and columns
   ↓
3. Parse CSV data
   ↓
4. Calculate residuals per unit
   ↓
5. Identify eligible MF debits (GL 500x)
   ↓
6. Distribute credits (largest first)
   ↓
7. Generate Excel with highlights
   ↓
8. Return statistics and download link
```

## Testing

### Run Tests

```bash
# Run all tests
bundle exec rspec

```

### Test Structure

```
spec/
├── controllers/
│   └── journal_entries_controller_spec.rb  # 70 tests
├── services/
│   └── journal_entry_processor_service_spec.rb  # 135 tests
└── spec_helper.rb  # SimpleCov configuration
```

### Coverage Requirements

Minimum 90% coverage enforced. If below 90%, tests will fail:

```ruby
# spec/spec_helper.rb
SimpleCov.start 'rails' do
  minimum_coverage 90
end
```

### Test Coverage

- **Current Coverage**: 90.3%

### Example Test Run Output

```bash
$ bundle exec rspec

JournalEntryProcessorService
  #initialize
    ✓ sets input and output paths
    ✓ initializes empty data array
  #process
    ✓ processes the file successfully
    ✓ generates Excel file
  ... (200+ more tests)

Finished in 3.5 seconds
205 examples, 0 failures

Coverage report generated
Line Coverage: 90.3% (277 / 300) 
```

## Example

**Input CSV:**
```csv
UNIT_NUMBER,GL_ACCOUNT,TRANSACTION,SOURCE,DEBIT_AMOUNT,CREDIT_AMOUNT,REFERENCE
129,5104,INVENTORY,INV,0,26.15,Factory Credit
129,5001,MF COST,MFG,852.00,0,Manufacturing
129,5002,MF LABOR,MFG,450.00,0,Labor
```

**Processing:**
- Unit 129 has GL 5104 credit: $26.15
- Largest MF debit: GL 5001 ($852.00)
- Apply credit: $852.00 - $26.15 = $825.85

**Output Excel:**
```
Row 2 (highlighted yellow):
UNIT_NUMBER: 129
GL_ACCOUNT: 5001
DEBIT_AMOUNT: 825.85 (adjusted from 852.00)
ADJUSTMENT_FLAG: "Adjusted by 26.15 (was 852.00)"
Total Adjusted: 26.15
```

## Project Structure

```
buyers_edge_processor/
├── app/
│   ├── controllers/
│   │   ├── journal_entries_controller.rb  # Main controller (upload/process/download)
│   │   └── help_controller.rb             # Help page controller
│   ├── services/
│   │   └── journal_entry_processor_service.rb  # Core business logic
│   ├── views/
│   │   ├── journal_entries/
│   │   │   ├── index.html.erb   # Upload form
│   │   │   └── result.html.erb  # Results page
│   │   └── help/
│   │       └── index.html.erb   # User guide
│   └── assets/
│       └── stylesheets/
│           └── application.css
├── config/
│   └── routes.rb                # URL routing
├── spec/
│   ├── controllers/
│   │   └── journal_entries_controller_spec.rb  # 70 tests
│   ├── services/
│   │   └── journal_entry_processor_service_spec.rb  # 135 tests
│   └── spec_helper.rb           # Test configuration
├── tmp/
│   ├── uploads/                 # Temporary CSV storage
│   └── outputs/                 # Generated Excel files
├── Gemfile                      # Dependencies
├── README.md                    # This file
└── .gitignore                   # Git ignore rules
```

## Error Handling

### Common Errors

**"CSV file is empty"**
- **Cause**: No data rows in CSV
- **Solution**: Ensure CSV has data after headers

**"Missing required columns"**
- **Cause**: CSV missing UNIT_NUMBER, GL_ACCOUNT, DEBIT_AMOUNT, or CREDIT_AMOUNT
- **Solution**: Re-export with all required columns

**"Please upload a valid CSV file"**
- **Cause**: File is not CSV format
- **Solution**: Ensure file ends with `.csv` and is text/csv format
- 


### How to Contribute
1. Fork the repository
2. Create a feature branch (`git checkout -b feature/api-endpoints`)
3. Make your changes
4. Add tests (maintain 90% coverage)
5. Commit (`git commit -m "Add API endpoints"`)
6. Push to branch (`git push origin feature/api-endpoints`)
7. Create Pull Request

