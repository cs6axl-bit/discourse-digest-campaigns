# frozen_string_literal: true

class AddSmtpProviderConstraintsToDigestCampaigns < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:digest_campaigns)

    # discourse-multi-smtp-router provider ids. Handed to the router per message through
    # headers (see DigestCampaigns.apply_smtp_provider_constraints!):
    #   only  -> the router may pick ONLY from these providers
    #   avoid -> the router never picks these providers
    unless column_exists?(:digest_campaigns, :smtp_only_provider_ids)
      add_column :digest_campaigns, :smtp_only_provider_ids, :jsonb, null: false, default: []
    end
    unless column_exists?(:digest_campaigns, :smtp_avoid_provider_ids)
      add_column :digest_campaigns, :smtp_avoid_provider_ids, :jsonb, null: false, default: []
    end
  end

  def down
    return unless table_exists?(:digest_campaigns)

    %i[smtp_only_provider_ids smtp_avoid_provider_ids].each do |col|
      remove_column :digest_campaigns, col if column_exists?(:digest_campaigns, col)
    end
  end
end
