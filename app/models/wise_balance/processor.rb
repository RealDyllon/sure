class WiseBalance::Processor
  attr_reader :wise_balance

  def initialize(wise_balance)
    @wise_balance = wise_balance
  end

  def process
    return unless wise_balance.current_account.present?

    process_account!
    process_transactions
  end

  private

    def process_account!
      wise_balance.current_account.update!(
        balance: wise_balance.current_balance || 0,
        cash_balance: wise_balance.current_balance || 0,
        currency: wise_balance.currency
      )
    end

    def process_transactions
      Array(wise_balance.raw_transactions_payload).each do |transaction_payload|
        WiseEntry::Processor.new(transaction_payload, wise_balance: wise_balance).process
      end
    end
end
