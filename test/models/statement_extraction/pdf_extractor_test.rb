require "test_helper"

class StatementExtraction::PdfExtractorTest < ActiveSupport::TestCase
  test "DBS consolidated PDF keeps separate accounts and repeated transactions" do
    provider = stub
    Provider::Registry.stubs(:preferred_llm_provider).returns(provider)
    provider.stubs(:class).returns(Provider::Openai)
    Provider::StatementExtractor.any_instance.expects(:extract).returns({ bank_name: "DBS", period: { end_date: "2026-04-30" }, accounts: [ { account_number: "1111", account_name: "Example Checking Account", currency: "SGD", closing_balance: "100", transactions: [ { date: "2026-04-01", name: "Example purchase", amount: "-12" }, { date: "2026-04-01", name: "Example purchase", amount: "-12" } ] }, { account_number: "2222", account_name: "Example Credit Account", account_type: "CreditCard", currency: "SGD", closing_balance: "20" } ] })
    import = StatementImport.new(family: families(:dylan_family))
    import.stubs(:pdf_file_content).returns("synthetic PDF")
    import.stubs(:original_filename).returns("dbs-example.pdf")
    result = StatementExtraction::PdfExtractor.new(import).extract
    assert_equal 2, result.accounts.size
    assert_equal 2, result.accounts.first["transactions"].size
    assert_equal "20", result.accounts.last["closing_balance"]
  end

  test "statement client uses provider-independent instructions and prompt" do
    provider = mock
    message = Provider::LlmConcept::ChatMessage.new(id: "example", output_text: '{"accounts":[]}')
    data = Provider::LlmConcept::ChatResponse.new(id: "example", model: "example", messages: [ message ], function_requests: [])
    provider.expects(:chat_response).with("Example text", instructions: "Extract JSON", model: "example", family: families(:dylan_family)).returns(Provider::Response.new(success?: true, data: data, error: nil))
    result = Provider::StatementClient.new(provider: provider, family: families(:dylan_family)).chat(parameters: { model: "example", messages: [ { role: "system", content: "Extract JSON" }, { role: "user", content: "Example text" } ] })
    assert_equal '{"accounts":[]}', result.dig("choices", 0, "message", "content")
  end

  test "PDF chunk normalization never collapses identical occurrences" do
    extractor = Provider::StatementExtractor.new(client: stub, pdf_content: "example", model: "example")
    row = { date: "2026-04-01", amount: "12", name: "Example purchase", chunk_index: 0 }
    rows = extractor.send(:deduplicate_transactions, [ row, row.dup, row.merge(chunk_index: 1) ])
    assert_equal 3, rows.size
    assert_not rows.first.key?(:chunk_index)
  end
end
