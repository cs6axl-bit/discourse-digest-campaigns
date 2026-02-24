# frozen_string_literal: true

module DigestCampaigns
  class Campaign < ActiveRecord::Base
    self.table_name = ::DigestCampaigns::CAMPAIGNS_TABLE

    validates :campaign_key, presence: true, uniqueness: true
    validates :selection_sql, presence: true
  end
end
