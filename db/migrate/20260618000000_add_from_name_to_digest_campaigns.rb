# frozen_string_literal: true

class AddFromNameToDigestCampaigns < ActiveRecord::Migration[7.0]
  def up
    add_column :digest_campaigns, :from_name, :text unless column_exists?(:digest_campaigns, :from_name)
  end

  def down
    remove_column :digest_campaigns, :from_name if column_exists?(:digest_campaigns, :from_name)
  end
end
