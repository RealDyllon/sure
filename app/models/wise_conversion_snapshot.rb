class WiseConversionSnapshot < ApplicationRecord
  belongs_to :wise_conversion_intention

  validates :observed_on, presence: true
end
