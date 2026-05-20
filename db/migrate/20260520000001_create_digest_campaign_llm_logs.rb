# frozen_string_literal: true

class CreateDigestCampaignLlmLogs < ActiveRecord::Migration[7.0]
  def up
    create_table :digest_campaign_llm_logs, force: false do |t|
      # Links to the regeneration attempt (null if the regenerations insert itself failed)
      t.integer  :regeneration_id

      # Which step produced this log entry
      t.string   :call_type, limit: 20   # 'text' or 'image'
      t.string   :stage,     limit: 80   # 'api_call', 'response_parse', 'image_upload', …

      # Model and request size
      t.string   :model, limit: 200
      t.integer  :request_body_bytes

      # Prompt sent to the model (first 2 KB)
      t.text     :prompt_snippet

      # HTTP-level response details
      t.integer  :http_status
      t.text     :response_body_snippet  # first 10 KB of raw response

      # Timing
      t.integer  :duration_ms

      # Outcome
      t.boolean  :success, null: false, default: false
      t.string   :error_class,    limit: 200
      t.text     :error_message
      t.text     :error_backtrace  # first 5 lines

      t.datetime :created_at, null: false, default: -> { "NOW()" }
    end

    add_index :digest_campaign_llm_logs, :regeneration_id
    add_index :digest_campaign_llm_logs, :created_at
    add_index :digest_campaign_llm_logs, :success
  end

  def down
    drop_table :digest_campaign_llm_logs, if_exists: true
  end
end
