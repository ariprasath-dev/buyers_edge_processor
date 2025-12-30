# Buyer's Edge Journal Entry Processor

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

1. Upload CSV with these columns:
   - UNIT_NUMBER, GL_ACCOUNT, DEBIT_AMOUNT, CREDIT_AMOUNT

2. Get Excel output with:
   - Yellow highlighting on adjusted rows
   - Summary sheet with totals

## Business Logic

```
For each unit:
  Residual = GL_5104_Credits - GL_5104_Debits
  
If residual > 0:
  Apply to largest MF debit first (GL 500x)
  Exclude service charges
```




### View Coverage Report

```bash
# Run tests (coverage automatically generated)
bundle exec rspec
```



### Test Structure

```
spec/
├── controllers/
│   └── journal_entries_controller_spec.rb  
├── services/
│   └── journal_entry_processor_service_spec.rb  
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

**Input:**
```csv
129,5104,0,26.15     # Credit
129,5001,852.00,0    # Debit
```

**Output:**
```
129,5001,825.85,0    # Adjusted (852 - 26.15)
Adjustment: "Adjusted by 26.15 (was 852.00)"
```

## Project Structure

```
app/
├── controllers/journal_entries_controller.rb
├── services/journal_entry_processor_service.rb
└── views/journal_entries/

spec/
├── controllers/ 
└── services/   
```

