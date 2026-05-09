require "test_helper"

class Provider::Openai::BankStatementExtractorTest < ActiveSupport::TestCase
  setup do
    @client = mock("openai_client")
    @model = "gpt-4.1"
  end

  test "extracts transactions from PDF content" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "Test Bank",
            "account_holder" => "John Doe",
            "account_number" => "1234",
            "statement_period" => {
              "start_date" => "2024-01-01",
              "end_date" => "2024-01-31"
            },
            "opening_balance" => 5000.00,
            "closing_balance" => 4500.00,
            "transactions" => [
              { "date" => "2024-01-15", "description" => "Coffee Shop", "amount" => -5.50 },
              { "date" => "2024-01-20", "description" => "Salary Deposit", "amount" => 3000.00 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    # Mock the PDF text extraction
    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 bank statement text" ])

    result = extractor.extract

    assert_equal "Test Bank", result[:bank_name]
    assert_equal "John Doe", result[:account_holder]
    assert_equal "1234", result[:account_number]
    assert_equal 5000.00, result[:opening_balance]
    assert_equal 4500.00, result[:closing_balance]
    assert_equal 2, result[:transactions].size

    first_txn = result[:transactions].first
    assert_equal "2024-01-15", first_txn[:date]
    assert_equal "Coffee Shop", first_txn[:name]
    assert_equal(-5.50, first_txn[:amount])
  end

  test "extracts multiple accounts from consolidated DBS statement response" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "DBS Bank",
            "account_holder" => "John Doe",
            "statement_period" => {
              "start_date" => "2026-04-01",
              "end_date" => "2026-04-30"
            },
            "accounts" => [
              {
                "account_name" => "Example Checking Account",
                "account_number" => "1234",
                "account_type" => "Depository",
                "subtype" => "checking",
                "currency" => "SGD",
                "opening_balance" => 1000.00,
                "closing_balance" => 900.00,
                "transactions" => [
                  { "date" => "2026-04-10", "description" => "Coffee", "amount" => -5.50, "currency" => "SGD" }
                ]
              },
              {
                "account_name" => "DBS Savings Plus",
                "account_number" => "5678",
                "account_type" => "Depository",
                "subtype" => "savings",
                "currency" => "SGD",
                "opening_balance" => 2000.00,
                "closing_balance" => 2500.00,
                "transactions" => [
                  { "date" => "2026-04-15", "description" => "Interest", "amount" => 1.25, "currency" => "SGD" }
                ]
              }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )
    extractor.stubs(:extract_pages_from_pdf).returns([ "DBS consolidated statement text" ])

    result = extractor.extract

    assert_equal "DBS Bank", result[:bank_name]
    assert_equal 2, result[:accounts].size

    current = result[:accounts].first
    savings = result[:accounts].second

    assert_equal "Example Checking Account", current[:account_name]
    assert_equal "1234", current[:account_number]
    assert_equal "checking", current[:subtype]
    assert_equal 900.00, current[:closing_balance]
    assert_equal 1, current[:transactions].size
    assert_equal "Coffee", current[:transactions].first[:name]

    assert_equal "DBS Savings Plus", savings[:account_name]
    assert_equal "5678", savings[:account_number]
    assert_equal "savings", savings[:subtype]
    assert_equal 2500.00, savings[:closing_balance]
    assert_equal 1, savings[:transactions].size
    assert_equal "Interest", savings[:transactions].first[:name]
  end

  test "merges DBS account chunks by normalized last four account number" do
    first_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "DBS Bank",
            "accounts" => [
              {
                "account_name" => "Example Checking Account",
                "account_number" => "120-852222-2",
                "account_type" => "Depository",
                "subtype" => "checking",
                "currency" => "SGD",
                "closing_balance" => 1234.56,
                "transactions" => []
              }
            ]
          }.to_json
        }
      } ]
    }
    second_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "accounts" => [
              {
                "account_name" => "Example Checking Account",
                "account_number" => "22222",
                "account_type" => "Depository",
                "subtype" => "checking",
                "currency" => "SGD",
                "closing_balance" => 9566.75,
                "transactions" => [
                  { "date" => "2026-04-30", "description" => "Interest Earned", "amount" => 0.02, "currency" => "SGD" }
                ]
              }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).twice.returns(first_response, second_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )
    extractor.stubs(:extract_pages_from_pdf).returns([
      "Page 1 " * 500,
      "Page 2 " * 500
    ])

    result = extractor.extract

    assert_equal 1, result[:accounts].size
    account = result[:accounts].first
    assert_equal "2222", account[:account_number]
    assert_equal "Example Checking Account", account[:account_name]
    assert_equal 1234.56, account[:closing_balance]
    assert_equal 1, account[:transactions].size
    assert_equal "Interest Earned", account[:transactions].first[:name]
  end

  test "does not merge accounts with same last four but incompatible metadata" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "DBS Bank",
            "accounts" => [
              {
                "account_name" => "Example Checking Account",
                "account_number" => "1234",
                "account_type" => "Depository",
                "subtype" => "checking",
                "currency" => "SGD",
                "closing_balance" => 900.00,
                "transactions" => [
                  { "date" => "2026-04-10", "description" => "Salary", "amount" => 1000.00, "currency" => "SGD" }
                ]
              },
              {
                "account_name" => "DBS Visa Card",
                "account_number" => "1234",
                "account_type" => "CreditCard",
                "subtype" => "credit_card",
                "currency" => "SGD",
                "closing_balance" => -120.00,
                "transactions" => [
                  { "date" => "2026-04-11", "description" => "Card Spend", "amount" => -45.00, "currency" => "SGD" }
                ]
              }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )
    extractor.stubs(:extract_pages_from_pdf).returns([ "DBS consolidated statement text" ])

    result = extractor.extract

    assert_equal 2, result[:accounts].size

    depository = result[:accounts].detect { |account| account[:account_type] == "Depository" }
    credit_card = result[:accounts].detect { |account| account[:account_type] == "CreditCard" }

    assert_equal "Example Checking Account", depository[:account_name]
    assert_equal 900.00, depository[:closing_balance]
    assert_equal [ "Salary" ], depository[:transactions].map { |transaction| transaction[:name] }

    assert_equal "DBS Visa Card", credit_card[:account_name]
    assert_equal(-120.00, credit_card[:closing_balance])
    assert_equal [ "Card Spend" ], credit_card[:transactions].map { |transaction| transaction[:name] }
  end

  test "merges DBS summary-only account chunk into same named activity account when key is missing" do
    first_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "DBS Bank",
            "accounts" => [
              {
                "account_name" => "Example Checking Account",
                "account_type" => "Depository",
                "subtype" => "savings",
                "currency" => "SGD",
                "closing_balance" => 10_751.51,
                "transactions" => []
              },
              {
                "account_name" => "Example Savings Account",
                "account_number" => "1111",
                "account_type" => "Depository",
                "subtype" => "savings",
                "currency" => "SGD",
                "closing_balance" => 234.56,
                "transactions" => []
              }
            ]
          }.to_json
        }
      } ]
    }
    second_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "accounts" => [
              {
                "account_name" => "Example Checking Account",
                "account_number" => "2222",
                "account_type" => "Depository",
                "subtype" => "savings",
                "currency" => "SGD",
                "closing_balance" => 10_982.97,
                "transactions" => [
                  { "date" => "2026-03-31", "description" => "Salary Credit", "amount" => 5000.00, "currency" => "SGD" }
                ]
              }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).twice.returns(first_response, second_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )
    extractor.stubs(:extract_pages_from_pdf).returns([
      "Page 1 " * 500,
      "Page 2 " * 500
    ])

    result = extractor.extract

    assert_equal 2, result[:accounts].size

    multiplier = result[:accounts].detect { |account| account[:account_name] == "Example Checking Account" }
    savings = result[:accounts].detect { |account| account[:account_name] == "Example Savings Account" }

    assert_equal "2222", multiplier[:account_number]
    assert_equal 10_751.51, multiplier[:closing_balance]
    assert_equal 1, multiplier[:transactions].size
    assert_equal "Salary Credit", multiplier[:transactions].first[:name]

    assert_equal "1111", savings[:account_number]
    assert_equal 234.56, savings[:closing_balance]
    assert_empty savings[:transactions]
  end

  test "does not merge accounts with same last four when name or subtype differs" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "DBS Bank",
            "accounts" => [
              {
                "account_name" => "DBS Current Account",
                "account_number" => "1234",
                "account_type" => "Depository",
                "subtype" => "checking",
                "currency" => "SGD",
                "closing_balance" => 900.00,
                "transactions" => [
                  { "date" => "2026-04-10", "description" => "Salary", "amount" => 1000.00, "currency" => "SGD" }
                ]
              },
              {
                "account_name" => "DBS Savings Account",
                "account_number" => "1234",
                "account_type" => "Depository",
                "subtype" => "savings",
                "currency" => "SGD",
                "closing_balance" => 1200.00,
                "transactions" => [
                  { "date" => "2026-04-11", "description" => "Interest", "amount" => 1.00, "currency" => "SGD" }
                ]
              }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )
    extractor.stubs(:extract_pages_from_pdf).returns([ "DBS consolidated statement text" ])

    result = extractor.extract

    assert_equal 2, result[:accounts].size
    assert_equal [ "DBS Current Account", "DBS Savings Account" ], result[:accounts].map { |account| account[:account_name] }
    assert_equal [ "checking", "savings" ], result[:accounts].map { |account| account[:subtype] }
  end

  test "does not merge same named summary and activity accounts when keys disagree" do
    first_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "DBS Bank",
            "accounts" => [
              {
                "account_name" => "Savings Account",
                "account_number" => "1111",
                "account_type" => "Depository",
                "subtype" => "savings",
                "currency" => "SGD",
                "closing_balance" => 500.00,
                "transactions" => []
              }
            ]
          }.to_json
        }
      } ]
    }
    second_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "accounts" => [
              {
                "account_name" => "Savings Account",
                "account_number" => "2222",
                "account_type" => "Depository",
                "subtype" => "savings",
                "currency" => "SGD",
                "closing_balance" => 750.00,
                "transactions" => [
                  { "date" => "2026-04-15", "description" => "Transfer", "amount" => 25.00, "currency" => "SGD" }
                ]
              }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).twice.returns(first_response, second_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )
    extractor.stubs(:extract_pages_from_pdf).returns([
      "Page 1 " * 500,
      "Page 2 " * 500
    ])

    result = extractor.extract

    assert_equal 2, result[:accounts].size
    assert_equal [ "1111", "2222" ], result[:accounts].map { |account| account[:account_number] }
    assert_equal [ 0, 1 ], result[:accounts].map { |account| account[:transactions].size }
  end

  test "preserves chunk indexes across repeated account merges" do
    first_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "DBS Bank",
            "accounts" => [
              {
                "account_name" => "Example Checking Account",
                "account_number" => "2222",
                "account_type" => "Depository",
                "subtype" => "checking",
                "currency" => "SGD",
                "transactions" => [
                  { "date" => "2026-04-01", "description" => "Opening Transfer", "amount" => 100.00, "currency" => "SGD" }
                ]
              }
            ]
          }.to_json
        }
      } ]
    }
    second_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "accounts" => [
              {
                "account_name" => "Example Checking Account",
                "account_number" => "2222",
                "account_type" => "Depository",
                "subtype" => "checking",
                "currency" => "SGD",
                "transactions" => [
                  { "date" => "2026-04-01", "description" => "Opening Transfer", "amount" => 100.00, "currency" => "SGD" },
                  { "date" => "2026-04-02", "description" => "Card Spend", "amount" => -20.00, "currency" => "SGD" }
                ]
              }
            ]
          }.to_json
        }
      } ]
    }
    third_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "accounts" => [
              {
                "account_name" => "Example Checking Account",
                "account_number" => "2222",
                "account_type" => "Depository",
                "subtype" => "checking",
                "currency" => "SGD",
                "transactions" => [
                  { "date" => "2026-04-02", "description" => "Card Spend", "amount" => -20.00, "currency" => "SGD" },
                  { "date" => "2026-04-03", "description" => "Interest", "amount" => 0.02, "currency" => "SGD" }
                ]
              }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).times(3).returns(first_response, second_response, third_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )
    extractor.stubs(:extract_pages_from_pdf).returns([
      "Page 1 " * 500,
      "Page 2 " * 500,
      "Page 3 " * 500
    ])

    result = extractor.extract

    account = result[:accounts].first
    assert_equal 1, result[:accounts].size
    assert_equal [ "Opening Transfer", "Card Spend", "Interest" ], account[:transactions].map { |transaction| transaction[:name] }
  end

  test "uses net liquidation value when account closing balance is blank and keeps cash transactions" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "Interactive Brokers",
            "accounts" => [
              {
                "account_name" => "IBKR Brokerage",
                "account_id" => "U1234567",
                "account_type" => "Investment",
                "subtype" => "brokerage",
                "base_currency" => "USD",
                "closing_balance" => "",
                "net_liquidation_value" => "7100.00",
                "transactions" => [],
                "cash_transactions" => [
                  { "date" => "2026-04-15", "description" => "AAPL Dividend", "amount" => 12.34, "currency" => "USD" }
                ]
              }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )
    extractor.stubs(:extract_pages_from_pdf).returns([ "IBKR activity statement" ])

    result = extractor.extract

    account = result[:accounts].first
    assert_equal 7100.00, account[:closing_balance]
    assert_equal 7100.00, account[:net_liquidation_value]
    assert_equal 1, account[:transactions].size
    assert_equal "AAPL Dividend", account[:transactions].first[:name]
  end

  test "merges chunks when account id and account number identify same suffix" do
    first_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "Interactive Brokers",
            "accounts" => [
              {
                "account_name" => "IBKR Brokerage",
                "account_id" => "U1234567",
                "account_type" => "Investment",
                "subtype" => "brokerage",
                "base_currency" => "USD",
                "transactions" => [
                  { "date" => "2026-04-15", "description" => "Dividend", "amount" => 12.34, "currency" => "USD" }
                ]
              }
            ]
          }.to_json
        }
      } ]
    }
    second_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "accounts" => [
              {
                "account_name" => "IBKR Brokerage",
                "account_number" => "4567",
                "account_type" => "Investment",
                "subtype" => "brokerage",
                "base_currency" => "USD",
                "transactions" => [
                  { "date" => "2026-04-16", "description" => "Deposit", "amount" => 1000.00, "currency" => "USD" }
                ]
              }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).twice.returns(first_response, second_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )
    extractor.stubs(:extract_pages_from_pdf).returns([
      "Page 1 " * 500,
      "Page 2 " * 500
    ])

    result = extractor.extract

    account = result[:accounts].first
    assert_equal 1, result[:accounts].size
    assert_equal "U1234567", account[:account_id]
    assert_equal "4567", account[:account_number]
    assert_equal [ "Dividend", "Deposit" ], account[:transactions].map { |transaction| transaction[:name] }
  end

  test "handles empty PDF content" do
    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "",
      model: @model
    )

    assert_raises(Provider::Openai::Error) do
      extractor.extract
    end
  end

  test "handles nil PDF content" do
    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: nil,
      model: @model
    )

    assert_raises(Provider::Openai::Error) do
      extractor.extract
    end
  end

  test "deduplicates transactions across chunk boundaries" do
    # First chunk response
    first_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "Test Bank",
            "account_holder" => "John Doe",
            "account_number" => "1234",
            "statement_period" => { "start_date" => "2024-01-01", "end_date" => "2024-01-31" },
            "opening_balance" => 5000.00,
            "closing_balance" => 4500.00,
            "transactions" => [
              { "date" => "2024-01-15", "description" => "Coffee Shop", "amount" => -5.50 },
              { "date" => "2024-01-16", "description" => "Grocery Store", "amount" => -50.00 }
            ]
          }.to_json
        }
      } ]
    }

    # Second chunk response with duplicate at boundary
    second_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "transactions" => [
              { "date" => "2024-01-16", "description" => "Grocery Store", "amount" => -50.00 },
              { "date" => "2024-01-17", "description" => "Gas Station", "amount" => -40.00 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).twice.returns(first_response, second_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    # Mock multiple pages that will create multiple chunks
    extractor.stubs(:extract_pages_from_pdf).returns([
      "Page 1 " * 500,  # ~3500 chars, first chunk
      "Page 2 " * 500   # ~3500 chars, second chunk
    ])

    result = extractor.extract

    # Should deduplicate the "Grocery Store" transaction at chunk boundary
    assert_equal 3, result[:transactions].size
    names = result[:transactions].map { |t| t[:name] }
    assert_includes names, "Coffee Shop"
    assert_includes names, "Grocery Store"
    assert_includes names, "Gas Station"
  end

  test "emits progress callback before processing chunks" do
    first_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "bank_name" => "Test Bank",
            "transactions" => []
          }.to_json
        }
      } ]
    }
    second_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "transactions" => []
          }.to_json
        }
      } ]
    }
    events = []

    @client.expects(:chat).twice.returns(first_response, second_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model,
      progress_callback: ->(**event) { events << event }
    )
    extractor.stubs(:extract_pages_from_pdf).returns([
      "Page 1 " * 500,
      "Page 2 " * 500
    ])

    extractor.extract

    assert_equal [
      { current: 0, total: 2, message: "Preparing 2 chunks" },
      { current: 1, total: 2, message: "Processing chunk 1 of 2" },
      { current: 2, total: 2, message: "Processing chunk 2 of 2" }
    ], events
  end

  test "normalizes transaction amounts" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => {
            "transactions" => [
              { "date" => "2024-01-15", "description" => "Test 1", "amount" => "-$5.50" },
              { "date" => "2024-01-16", "description" => "Test 2", "amount" => "1,234.56" },
              { "date" => "2024-01-17", "description" => "Test 3", "amount" => -100 }
            ]
          }.to_json
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 text" ])

    result = extractor.extract

    assert_equal(-5.50, result[:transactions][0][:amount])
    assert_equal 1234.56, result[:transactions][1][:amount]
    assert_equal(-100.0, result[:transactions][2][:amount])
  end

  test "handles malformed JSON response gracefully" do
    mock_response = {
      "choices" => [ {
        "message" => {
          "content" => "This is not valid JSON"
        }
      } ]
    }

    @client.expects(:chat).returns(mock_response)

    extractor = Provider::Openai::BankStatementExtractor.new(
      client: @client,
      pdf_content: "dummy",
      model: @model
    )

    extractor.stubs(:extract_pages_from_pdf).returns([ "Page 1 text" ])

    result = extractor.extract

    # Should return empty transactions on parse error
    assert_equal [], result[:transactions]
  end
end
