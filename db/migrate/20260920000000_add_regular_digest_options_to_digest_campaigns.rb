# frozen_string_literal: true

class AddRegularDigestOptionsToDigestCampaigns < ActiveRecord::Migration[7.0]
  def up
    return unless table_exists?(:digest_campaigns)

    # "Regular digest" campaign: no HTML / topic sets. Each queued user is sent the
    # normal Discourse digest (so digest plugins such as promo-digest-injector run).
    unless column_exists?(:digest_campaigns, :regular_digest)
      add_column :digest_campaigns, :regular_digest, :boolean, null: false, default: false
    end

    # Sub-options (only meaningful when regular_digest = true); they are handed to the
    # injector's VSL campaign flow through Thread.current[:digest_campaign_vsl_override].
    unless column_exists?(:digest_campaigns, :vsl_direct)
      add_column :digest_campaigns, :vsl_direct, :boolean, null: false, default: false
    end
    unless column_exists?(:digest_campaigns, :vsl_skip_coinflip)
      add_column :digest_campaigns, :vsl_skip_coinflip, :boolean, null: false, default: false
    end
    unless column_exists?(:digest_campaigns, :vsl_ignore_min_emails)
      add_column :digest_campaigns, :vsl_ignore_min_emails, :boolean, null: false, default: false
    end
    unless column_exists?(:digest_campaigns, :vsl_allowed_sources)
      add_column :digest_campaigns, :vsl_allowed_sources, :jsonb, null: false, default: []
    end
  end

  def down
    return unless table_exists?(:digest_campaigns)

    %i[regular_digest vsl_direct vsl_skip_coinflip vsl_ignore_min_emails vsl_allowed_sources].each do |col|
      remove_column :digest_campaigns, col if column_exists?(:digest_campaigns, col)
    end
  end
end
