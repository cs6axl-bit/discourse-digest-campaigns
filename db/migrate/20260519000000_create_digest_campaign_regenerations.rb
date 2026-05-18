# frozen_string_literal: true

class CreateDigestCampaignRegenerations < ActiveRecord::Migration[7.0]
  def up
    create_table :digest_campaign_regenerations, force: false do |t|
      # Input — original email data
      t.text   :source_subject_line_1
      t.text   :source_subject_line_2
      t.text   :source_subject_line_3
      t.text   :source_preheader_line_1
      t.text   :source_preheader_line_2
      t.text   :source_html

      # Flags
      t.boolean :do_text,  null: false, default: true
      t.boolean :do_image, null: false, default: true
      t.text    :text_note
      t.text    :image_note

      # Text LLM result
      t.text    :text_prompt
      t.text    :result_subject_line_1
      t.text    :result_subject_line_2
      t.text    :result_subject_line_3
      t.text    :result_preheader_line_1
      t.text    :result_preheader_line_2
      t.text    :result_html

      # Image generation result
      t.text    :image_prompt
      t.text    :new_image_discourse_url
      t.text    :result_html_with_image

      # Metadata
      t.string  :gemini_text_model,  limit: 200
      t.string  :gemini_image_model, limit: 200

      t.datetime :created_at, null: false, default: -> { "NOW()" }
    end

    add_index :digest_campaign_regenerations, :created_at
  end

  def down
    drop_table :digest_campaign_regenerations, if_exists: true
  end
end
