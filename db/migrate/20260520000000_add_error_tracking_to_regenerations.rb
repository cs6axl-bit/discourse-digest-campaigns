# frozen_string_literal: true

class AddErrorTrackingToRegenerations < ActiveRecord::Migration[7.0]
  def up
    add_column :digest_campaign_regenerations, :error_stage,   :string, limit: 100
    add_column :digest_campaign_regenerations, :error_message, :text
    add_column :digest_campaign_regenerations, :duration_ms,   :integer
  end

  def down
    remove_column :digest_campaign_regenerations, :error_stage
    remove_column :digest_campaign_regenerations, :error_message
    remove_column :digest_campaign_regenerations, :duration_ms
  end
end
