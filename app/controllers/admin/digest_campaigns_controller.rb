# frozen_string_literal: true

require "securerandom"

module Admin
  class DigestCampaignsController < Admin::AdminController
    requires_plugin ::DigestCampaigns::PLUGIN_NAME

    PER_PAGE = 30

    def index
      page = (params[:page].to_i <= 0) ? 1 : params[:page].to_i
      per_page = PER_PAGE
      offset = (page - 1) * per_page

      scope = DigestCampaigns::Campaign.all

      if truthy_param?(params[:hide_hardsale], default: false)
        scope = scope.where("campaign_key NOT LIKE 'hardsale_topic_%'")
      end

      if (search = params[:search].to_s.strip).present?
        scope = scope.where("campaign_key ILIKE ?", "%#{search}%")
      end

      if (after = params[:created_after].to_s.strip).present?
        begin
          scope = scope.where("created_at >= ?", Time.zone.parse(after).beginning_of_day)
        rescue ArgumentError
          # ignore invalid date
        end
      end

      if (before_date = params[:created_before].to_s.strip).present?
        begin
          scope = scope.where("created_at <= ?", Time.zone.parse(before_date).end_of_day)
        rescue ArgumentError
          # ignore invalid date
        end
      end

      total = scope.count
      total_pages = [(total.to_f / per_page).ceil, 1].max

      rows = scope.order("created_at DESC").limit(per_page).offset(offset).map do |c|
        c.as_json.merge(
          queued_count: queue_count(c.campaign_key, "queued"),
          processing_count: queue_count(c.campaign_key, "processing"),
          sent_count: queue_count(c.campaign_key, "sent"),
          failed_count: queue_count(c.campaign_key, "failed"),
          skipped_unsubscribed_count: queue_count(c.campaign_key, "skipped_unsubscribed")
        )
      end

      render_json_dump(
        campaigns: rows,
        meta: {
          page: page,
          per_page: per_page,
          total: total,
          total_pages: total_pages
        }
      )
    end

    def create
      key = params.require(:campaign_key).to_s.strip
      sql = ::DigestCampaigns.validate_campaign_sql!(params.require(:selection_sql).to_s)
      sql = normalize_selection_sql!(sql)

      custom_html_body = params[:custom_html_body].to_s
      preheader_line_1 = params[:preheader_line_1].to_s
      preheader_line_2 = params[:preheader_line_2].to_s

      subject_line_1 = params[:subject_line_1].to_s
      subject_line_2 = params[:subject_line_2].to_s
      subject_line_3 = params[:subject_line_3].to_s
      from_name = params[:from_name].to_s.strip

      # Basic safety limit (avoid multi-MB payloads in the DB / JSON API)
      if custom_html_body.bytesize > 500_000
        raise ArgumentError, "custom_html_body is too large (max 500KB)"
      end

      exclude_recent = truthy_param?(params[:exclude_recent_from_queue], default: true)
      exclude_days = int_param?(params[:exclude_recent_from_queue_days], default: 1)
      exclude_days = 0 if exclude_days < 0
      exclude_days = 3650 if exclude_days > 3650

      exclude_recent_emailed = truthy_param?(params[:exclude_recent_emailed], default: true)
      exclude_emailed_days = int_param?(params[:exclude_recent_emailed_days], default: 1)
      exclude_emailed_days = 0 if exclude_emailed_days < 0
      exclude_emailed_days = 3650 if exclude_emailed_days > 3650

      set1 = ::DigestCampaigns.parse_topic_set_csv(params[:topic_set_1])
      set2 = ::DigestCampaigns.parse_topic_set_csv(params[:topic_set_2])
      set3 = ::DigestCampaigns.parse_topic_set_csv(params[:topic_set_3])
      topic_sets = [set1, set2, set3].reject(&:blank?)

      if custom_html_body.to_s.strip.blank?
        raise ArgumentError, "You must provide at least one topic set (topic_set_1/2/3) OR a custom_html_body" if topic_sets.empty?
      end
      raise ArgumentError, "You can provide at most 3 topic sets" if topic_sets.length > 3

      send_at = parse_send_at(params[:send_at])
      test_email = params[:test_email].to_s.strip

      c = DigestCampaigns::Campaign.new(
        campaign_key: key,
        selection_sql: sql,
        enabled: true,
        topic_sets: topic_sets,
        send_at: send_at,
        custom_html_body: custom_html_body,
        preheader_line_1: preheader_line_1,
        preheader_line_2: preheader_line_2,
        subject_line_1: subject_line_1,
        subject_line_2: subject_line_2,
        subject_line_3: subject_line_3,
        from_name: from_name.presence
      )
      c.save!

      populate_queue_for_campaign!(
        c,
        exclude_recent_from_queue: exclude_recent,
        exclude_recent_days: exclude_days,
        exclude_recent_emailed: exclude_recent_emailed,
        exclude_emailed_days: exclude_emailed_days
      )
      c.update_columns(last_error: nil, last_populated_at: Time.zone.now, updated_at: Time.zone.now)

      test_result = test_email.present? ? send_test_now!(c, test_email) : nil

      render_json_dump(ok: true, campaign: c.as_json, test: test_result)
    rescue => e
      render_json_error(e.message)
    end

    def show
      c = find_campaign
      render_json_dump(ok: true, campaign: c.as_json)
    rescue => e
      render_json_error(e.message)
    end

    def enable
      c = find_campaign
      c.update!(enabled: true)
      render_json_dump(ok: true, campaign: c.as_json)
    rescue => e
      render_json_error(e.message)
    end

    def disable
      c = find_campaign
      c.update!(enabled: false)
      render_json_dump(ok: true, campaign: c.as_json)
    rescue => e
      render_json_error(e.message)
    end

    def destroy
      c = find_campaign
      delete_queued = truthy_param?(params[:delete_queued_rows], default: true)

      if delete_queued
        DB.exec(<<~SQL, k: c.campaign_key.to_s)
          DELETE FROM #{::DigestCampaigns::QUEUE_TABLE}
          WHERE campaign_key = :k
            AND status = 'queued'
        SQL
      end

      c.destroy!
      render_json_dump(ok: true)
    rescue => e
      render_json_error(e.message)
    end

    def test_send
      c = find_campaign
      test_email = params.require(:test_email).to_s.strip
      res = send_test_now!(c, test_email)
      render_json_dump(ok: true, test: res)
    rescue => e
      render_json_error(e.message)
    end

    # Send a test email using the *draft* form fields, without creating/saving a campaign.
    def test_draft
      key = params[:campaign_key].to_s.strip
      key = "draft_#{SecureRandom.hex(4)}" if key.blank?

      sql = ::DigestCampaigns.validate_campaign_sql!(params.require(:selection_sql).to_s)
      sql = normalize_selection_sql!(sql)

      custom_html_body = params[:custom_html_body].to_s
      preheader_line_1 = params[:preheader_line_1].to_s
      preheader_line_2 = params[:preheader_line_2].to_s

      subject_line_1 = params[:subject_line_1].to_s
      subject_line_2 = params[:subject_line_2].to_s
      subject_line_3 = params[:subject_line_3].to_s
      from_name = params[:from_name].to_s.strip

      if custom_html_body.bytesize > 500_000
        raise ArgumentError, "custom_html_body is too large (max 500KB)"
      end

      set1 = ::DigestCampaigns.parse_topic_set_csv(params[:topic_set_1])
      set2 = ::DigestCampaigns.parse_topic_set_csv(params[:topic_set_2])
      set3 = ::DigestCampaigns.parse_topic_set_csv(params[:topic_set_3])
      topic_sets = [set1, set2, set3].reject(&:blank?)

      if custom_html_body.to_s.strip.blank?
        raise ArgumentError, "You must provide at least one topic set (topic_set_1/2/3) OR a custom_html_body" if topic_sets.empty?
      end
      raise ArgumentError, "You can provide at most 3 topic sets" if topic_sets.length > 3

      test_email = params.require(:test_email).to_s.strip
      send_at = parse_send_at(params[:send_at])

      chosen = ::DigestCampaigns.pick_random_topic_set(topic_sets)
      res =
        send_test_digest!(
          campaign_key: key,
          test_email: test_email,
          topic_ids: chosen,
          send_at: send_at,
          custom_html_body: custom_html_body,
          preheader_line_1: preheader_line_1,
          preheader_line_2: preheader_line_2,
          subject_line_1: subject_line_1,
          subject_line_2: subject_line_2,
          subject_line_3: subject_line_3,
          from_name: from_name.presence
        )
      render_json_dump(ok: true, test: res)
    rescue => e
      render_json_error(e.message)
    end

    # Count how many rows the supplied selection_sql would return.
    def count_records
      sql = ::DigestCampaigns.validate_campaign_sql!(params.require(:selection_sql).to_s)
      sql = normalize_selection_sql!(sql)

      exclude_recent = truthy_param?(params[:exclude_recent_from_queue], default: true)
      exclude_days = int_param?(params[:exclude_recent_from_queue_days], default: 1)
      exclude_days = 0 if exclude_days < 0
      exclude_days = 3650 if exclude_days > 3650

      exclude_recent_emailed = truthy_param?(params[:exclude_recent_emailed], default: true)
      exclude_emailed_days = int_param?(params[:exclude_recent_emailed_days], default: 1)
      exclude_emailed_days = 0 if exclude_emailed_days < 0
      exclude_emailed_days = 3650 if exclude_emailed_days > 3650

      effective_sql = apply_recent_queue_exclusion(
        sql,
        exclude_recent_from_queue: exclude_recent,
        exclude_recent_days: exclude_days
      )
      effective_sql = apply_recent_emailed_exclusion(
        effective_sql,
        exclude_recent_emailed: exclude_recent_emailed,
        exclude_emailed_days: exclude_emailed_days
      )

      count = DB.query_single("SELECT COUNT(*) FROM (#{effective_sql}) src").first.to_i
      render_json_dump(ok: true, count: count)
    rescue => e
      render_json_error(e.message)
    end


    def hardsale_email_html
      id = params.require(:id).to_i
      raise Discourse::InvalidParameters.new(:id) if id <= 0

      row = DB.query_single(<<~SQL, id: id)
        SELECT
          id,
          subject_titles_json,
          preheaders_json,
          preheader,
          html_full
        FROM aiwrites_hardsale_email_htmls
        WHERE id = :id
        LIMIT 1
      SQL

      raise Discourse::NotFound unless row.present?

      record_id, subject_titles_json, preheaders_json, legacy_preheader, html_full = row

      subjects = parse_json_string_array(subject_titles_json)
      preheaders = parse_json_string_array(preheaders_json)

      if preheaders.blank? && legacy_preheader.present?
        preheaders = [legacy_preheader.to_s]
      end

      subjects = normalize_fixed_length_array(subjects, 3)
      preheaders = normalize_fixed_length_array(preheaders, 2)

      render_json_dump(
        ok: true,
        source: {
          id: record_id.to_i,
          subject_line_1: subjects[0],
          subject_line_2: subjects[1],
          subject_line_3: subjects[2],
          preheader_line_1: preheaders[0],
          preheader_line_2: preheaders[1],
          custom_html_body: html_full.to_s
        }
      )
    rescue Discourse::NotFound
      raise
    rescue => e
      render_json_error(e.message)
    end

    # Load subjects, preheaders, and full HTML from aiwrites_hardsale_bundle_emails by id.
    # The bundle table is written by Test100_hardsale_multi_product_email and contains
    # multi-product emails; columns map identically to the single-product table.
    def bundle_email_html
      id = params.require(:id).to_i
      raise Discourse::InvalidParameters.new(:id) if id <= 0

      row = DB.query_single(<<~SQL, id: id)
        SELECT
          id,
          subject_titles_json,
          preheaders_json,
          preheader,
          html_full
        FROM aiwrites_hardsale_bundle_emails
        WHERE id = :id
        LIMIT 1
      SQL

      raise Discourse::NotFound unless row.present?

      record_id, subject_titles_json, preheaders_json, legacy_preheader, html_full = row

      subjects  = parse_json_string_array(subject_titles_json)
      preheaders = parse_json_string_array(preheaders_json)

      if preheaders.blank? && legacy_preheader.present?
        preheaders = [legacy_preheader.to_s]
      end

      subjects   = normalize_fixed_length_array(subjects,   3)
      preheaders = normalize_fixed_length_array(preheaders, 2)

      render_json_dump(
        ok: true,
        source: {
          id:               record_id.to_i,
          subject_line_1:   subjects[0],
          subject_line_2:   subjects[1],
          subject_line_3:   subjects[2],
          preheader_line_1: preheaders[0],
          preheader_line_2: preheaders[1],
          custom_html_body: html_full.to_s
        }
      )
    rescue Discourse::NotFound
      raise
    rescue => e
      render_json_error(e.message)
    end

    def vsl2html_email_html
      id = params.require(:id).to_i
      raise Discourse::InvalidParameters.new(:id) if id <= 0

      row = DB.query_single(<<~SQL, id: id)
        SELECT
          id,
          subject_titles_json,
          preheaders_json,
          html_full
        FROM vsl2html_email_outputs
        WHERE id = :id
        LIMIT 1
      SQL

      raise Discourse::NotFound unless row.present?

      record_id, subject_titles_json, preheaders_json, html_full = row

      subjects   = normalize_fixed_length_array(parse_json_string_array(subject_titles_json), 3)
      preheaders = normalize_fixed_length_array(parse_json_string_array(preheaders_json), 2)

      render_json_dump(
        ok: true,
        source: {
          id:               record_id.to_i,
          subject_line_1:   subjects[0],
          subject_line_2:   subjects[1],
          subject_line_3:   subjects[2],
          preheader_line_1: preheaders[0],
          preheader_line_2: preheaders[1],
          custom_html_body: html_full.to_s
        }
      )
    rescue Discourse::NotFound
      raise
    rescue => e
      render_json_error(e.message)
    end

    def web2html_email_html
      id = params.require(:id).to_i
      raise Discourse::InvalidParameters.new(:id) if id <= 0

      row = DB.query_single(<<~SQL, id: id)
        SELECT
          id,
          subject_titles_json,
          preheaders_json,
          html_full
        FROM webpage2html_email_outputs
        WHERE id = :id
        LIMIT 1
      SQL

      raise Discourse::NotFound unless row.present?

      record_id, subject_titles_json, preheaders_json, html_full = row

      subjects   = normalize_fixed_length_array(parse_json_string_array(subject_titles_json), 3)
      preheaders = normalize_fixed_length_array(parse_json_string_array(preheaders_json), 2)

      render_json_dump(
        ok: true,
        source: {
          id:               record_id.to_i,
          subject_line_1:   subjects[0],
          subject_line_2:   subjects[1],
          subject_line_3:   subjects[2],
          preheader_line_1: preheaders[0],
          preheader_line_2: preheaders[1],
          custom_html_body: html_full.to_s
        }
      )
    rescue Discourse::NotFound
      raise
    rescue => e
      render_json_error(e.message)
    end

    def regenerate
      api_key = SiteSetting.digest_campaigns_gemini_api_key.to_s.strip
      raise ArgumentError, "digest_campaigns_gemini_api_key site setting is not configured" if api_key.blank?

      subject_line_1   = params[:subject_line_1].to_s
      subject_line_2   = params[:subject_line_2].to_s
      subject_line_3   = params[:subject_line_3].to_s
      preheader_line_1 = params[:preheader_line_1].to_s
      preheader_line_2 = params[:preheader_line_2].to_s
      html_body        = params[:html_body].to_s

      do_text  = truthy_param?(params[:do_text],  default: true)
      do_image = truthy_param?(params[:do_image], default: true)
      text_note  = params[:text_note].to_s.strip
      image_note = params[:image_note].to_s.strip

      raise ArgumentError, "html_body is required" if html_body.strip.blank?
      raise ArgumentError, "Select at least one of do_text or do_image" unless do_text || do_image

      service = ::DigestCampaigns::GeminiRegenerationService.new(
        api_key:          api_key,
        subject_line_1:   subject_line_1,
        subject_line_2:   subject_line_2,
        subject_line_3:   subject_line_3,
        preheader_line_1: preheader_line_1,
        preheader_line_2: preheader_line_2,
        html_body:        html_body,
        do_text:          do_text,
        do_image:         do_image,
        text_note:        text_note,
        image_note:       image_note
      )

      result = service.run!
      render_json_dump(ok: true, result: result)
    rescue => e
      render_json_error(e.message)
    end

    private

    def parse_json_string_array(raw)
      return [] if raw.blank?

      parsed = JSON.parse(raw)
      return [] unless parsed.is_a?(Array)

      parsed.map { |v| v.to_s.strip }.reject(&:blank?)
    rescue JSON::ParserError
      [raw.to_s.strip].reject(&:blank?)
    end

    def normalize_fixed_length_array(values, target_len)
      arr = Array(values).map { |v| v.to_s.strip }
      arr = arr.reject(&:blank?)
      arr = arr.first(target_len)
      while arr.length < target_len
        arr << ""
      end
      arr
    end


    def find_campaign
      DigestCampaigns::Campaign.find(params.require(:id))
    end

    def queue_count(campaign_key, status)
      DB.query_single(<<~SQL, k: campaign_key.to_s, s: status.to_s).first.to_i
        SELECT COUNT(*) FROM #{::DigestCampaigns::QUEUE_TABLE}
        WHERE campaign_key = :k AND status = :s
      SQL
    end

    def parse_send_at(v)
      s = v.to_s.strip
      return nil if s.blank?
      Time.zone.parse(s)
    rescue
      raise ArgumentError, "Invalid send_at datetime: #{s}"
    end

    def populate_queue_for_campaign!(campaign, exclude_recent_from_queue: true, exclude_recent_days: 1, exclude_recent_emailed: true, exclude_emailed_days: 1)
      sql = ::DigestCampaigns.validate_campaign_sql!(campaign.selection_sql)
      sql = apply_recent_queue_exclusion(
        sql,
        exclude_recent_from_queue: exclude_recent_from_queue,
        exclude_recent_days: exclude_recent_days
      )
      sql = apply_recent_emailed_exclusion(
        sql,
        exclude_recent_emailed: exclude_recent_emailed,
        exclude_emailed_days: exclude_emailed_days
      )

      DB.exec(<<~SQL, campaign_key: campaign.campaign_key.to_s, nb: campaign.send_at)
        INSERT INTO #{::DigestCampaigns::QUEUE_TABLE}
          (campaign_key, user_id, chosen_topic_ids, not_before, status, created_at, updated_at)
        SELECT
          :campaign_key AS campaign_key,
          src.user_id::int AS user_id,
          '{}'::int[] AS chosen_topic_ids,
          :nb AS not_before,
          'queued' AS status,
          NOW() AS created_at,
          NOW() AS updated_at
        FROM (#{sql}) src
        ON CONFLICT (campaign_key, user_id)
        DO UPDATE SET
          status = CASE
            WHEN #{::DigestCampaigns::QUEUE_TABLE}.status = 'sent' THEN 'sent'
            ELSE 'queued'
          END,
          not_before = CASE
            WHEN #{::DigestCampaigns::QUEUE_TABLE}.status = 'sent' THEN #{::DigestCampaigns::QUEUE_TABLE}.not_before
            ELSE EXCLUDED.not_before
          END,
          chosen_topic_ids = CASE
            WHEN #{::DigestCampaigns::QUEUE_TABLE}.status = 'sent' THEN #{::DigestCampaigns::QUEUE_TABLE}.chosen_topic_ids
            WHEN cardinality(#{::DigestCampaigns::QUEUE_TABLE}.chosen_topic_ids) > 0 THEN #{::DigestCampaigns::QUEUE_TABLE}.chosen_topic_ids
            ELSE '{}'::int[]
          END,
          locked_at = NULL,
          updated_at = NOW()
      SQL
    end

    # Exclude users who have any queue record within the last N days.
    # - For regular (non-delayed) queue rows (not_before IS NULL): exclude if created_at is within timeframe.
    # - For delayed queue rows (not_before IS NOT NULL): exclude ONLY if actually sent within timeframe.
    def apply_recent_queue_exclusion(selection_sql, exclude_recent_from_queue:, exclude_recent_days:)
      return selection_sql unless exclude_recent_from_queue

      days = exclude_recent_days.to_i
      return selection_sql if days <= 0

      cutoff = Time.zone.now - days.days
      cutoff_sql = ActiveRecord::Base.connection.quote(cutoff)

      <<~SQL
        WITH src AS (
          #{selection_sql}
        )
        SELECT src.*
        FROM src
        WHERE NOT EXISTS (
          SELECT 1
          FROM #{::DigestCampaigns::QUEUE_TABLE} q
          WHERE q.user_id = src.user_id::int
            AND (
              (q.not_before IS NULL AND q.created_at >= #{cutoff_sql})
              OR
              (q.not_before IS NOT NULL AND q.status = 'sent' AND q.sent_at IS NOT NULL AND q.sent_at >= #{cutoff_sql})
            )
        )
      SQL
    end

    # Exclude users whose last_emailed_at is within the last N days.
    def apply_recent_emailed_exclusion(selection_sql, exclude_recent_emailed:, exclude_emailed_days:)
      return selection_sql unless exclude_recent_emailed

      days = exclude_emailed_days.to_i
      return selection_sql if days <= 0

      cutoff = Time.zone.now - days.days
      cutoff_sql = ActiveRecord::Base.connection.quote(cutoff)

      <<~SQL
        WITH src AS (
          #{selection_sql}
        )
        SELECT src.*
        FROM src
        WHERE NOT EXISTS (
          SELECT 1
          FROM users u
          WHERE u.id = src.user_id::int
            AND u.last_emailed_at IS NOT NULL
            AND u.last_emailed_at >= #{cutoff_sql}
        )
      SQL
    end

    def truthy_param?(v, default: false)
      return default if v.nil?
      s = v.to_s.strip.downcase
      return true if %w[1 true t yes y on].include?(s)
      return false if %w[0 false f no n off].include?(s)
      default
    end

    def int_param?(v, default: 0)
      return default if v.nil?
      Integer(v)
    rescue
      default
    end

    def send_test_now!(campaign, test_email)
      chosen = ::DigestCampaigns.pick_random_topic_set(campaign.topic_sets)

      # Custom HTML campaigns do not require topic sets
      if campaign.custom_html_body.to_s.strip.blank?
        raise "Campaign has no topic sets configured" if chosen.blank?
      end

      send_test_digest!(
        campaign_key: campaign.campaign_key.to_s,
        test_email: test_email,
        topic_ids: chosen,
        send_at: campaign.send_at,
        campaign_id: campaign.id,
        custom_html_body: campaign.custom_html_body,
        preheader_line_1: campaign.preheader_line_1,
        preheader_line_2: campaign.preheader_line_2,
        subject_line_1: campaign.subject_line_1,
        subject_line_2: campaign.subject_line_2,
        subject_line_3: campaign.subject_line_3,
        from_name: campaign.from_name
      )
    end

    def send_test_digest!(
      campaign_key:,
      test_email:,
      topic_ids:,
      send_at: nil,
      campaign_id: nil,
      custom_html_body: nil,
      preheader_line_1: nil,
      preheader_line_2: nil,
      subject_line_1: nil,
      subject_line_2: nil,
      subject_line_3: nil,
      from_name: nil
    )
      user = User.find_by_email(test_email)
      raise "Test email not found as a Discourse user: #{test_email}" if user.nil?

      if custom_html_body.to_s.strip.blank?
        raise "No topic ids provided" if topic_ids.blank?
      end

      message =
        UserNotifications.digest(
          user,
          campaign_topic_ids: topic_ids,
          campaign_key: campaign_key.to_s,
          campaign_since: send_at,
          campaign_id: campaign_id,
          campaign_custom_html_body: custom_html_body,
          campaign_preheader_line_1: preheader_line_1,
          campaign_preheader_line_2: preheader_line_2,
          campaign_subject_line_1: subject_line_1,
          campaign_subject_line_2: subject_line_2,
          campaign_subject_line_3: subject_line_3,
          campaign_from_name: from_name
        )

      Email::Sender.new(message, :digest).send

      {
        sent_to: test_email,
        user_id: user.id,
        chosen_topic_ids: topic_ids,
        campaign_key: campaign_key.to_s,
        campaign_id: campaign_id,
        has_custom_html: custom_html_body.to_s.strip.present?
      }
    end

    # Detect whether the SQL returns user_id or an email column.
    # - If it returns user_id, return the SQL unchanged.
    # - If it returns user_email or email (from any table), wrap it with a
    #   JOIN to the Discourse users table to produce user_id.
    # - Otherwise raise an ArgumentError.
    def normalize_selection_sql!(sql)
      result = ActiveRecord::Base.connection.execute(
        "SELECT * FROM (#{sql}) _digest_campaigns_detect LIMIT 0"
      )
      cols = result.fields.map { |f| f.to_s.downcase }

      return sql if cols.include?("user_id")

      email_col =
        if cols.include?("user_email")
          "user_email"
        elsif cols.include?("email")
          "email"
        else
          raise ArgumentError,
                "selection_sql must return a column named user_id, user_email, or email. " \
                "Columns found: #{cols.join(', ')}"
        end

      <<~SQL.strip
        SELECT ue.user_id AS user_id
        FROM (#{sql}) _email_src
        JOIN user_emails ue ON LOWER(ue.email) = LOWER(_email_src.#{email_col})
          AND ue."primary" = true
        JOIN users u ON u.id = ue.user_id
        WHERE u.active = true
          AND u.staged = false
          AND u.id > 0
      SQL
    rescue ActiveRecord::StatementInvalid => e
      raise ArgumentError, "selection_sql is not valid SQL: #{e.message}"
    end
  end
end
