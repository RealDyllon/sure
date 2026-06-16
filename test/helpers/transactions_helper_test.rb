require "test_helper"

class TransactionsHelperTest < ActionView::TestCase
  include TransactionsHelper

  test "wise extras omits internal balance_id and card_id" do
    tx = OpenStruct.new(
      extra: {
        "wise" => {
          "balance_id" => "12345",
          "card_id" => "card-999",
          "card_last_four" => "4242",
          "transaction_type" => "CARD"
        }
      }
    )

    details = build_transaction_extra_details(tx)

    assert_equal :wise, details[:kind]
    assert_equal %w[card_last_four transaction_type], details[:wise].keys.sort
    assert_equal "4242", details[:wise]["card_last_four"]
    assert_equal "CARD", details[:wise]["transaction_type"]
    assert_nil details[:wise]["balance_id"]
    assert_nil details[:wise]["card_id"]
  end
end
