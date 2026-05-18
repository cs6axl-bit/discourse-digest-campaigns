# frozen_string_literal: true

require "net/http"
require "json"
require "base64"
require "tempfile"

module DigestCampaigns
  class GeminiRegenerationService
    GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models"

    HTML_TRUNCATE_FOR_IMAGE_PROMPT = 5_000

    def initialize(
      api_key:,
      subject_line_1:,
      subject_line_2:,
      subject_line_3:,
      preheader_line_1:,
      preheader_line_2:,
      html_body:,
      do_text:,
      do_image:,
      text_note:,
      image_note:
    )
      @api_key          = api_key
      @subject_line_1   = subject_line_1.to_s
      @subject_line_2   = subject_line_2.to_s
      @subject_line_3   = subject_line_3.to_s
      @preheader_line_1 = preheader_line_1.to_s
      @preheader_line_2 = preheader_line_2.to_s
      @html_body        = html_body.to_s
      @do_text          = do_text
      @do_image         = do_image
      @text_note        = text_note.to_s.strip
      @image_note       = image_note.to_s.strip
    end

    # Returns a hash with keys:
    #   subject_line_1..3, preheader_line_1..2, html_body
    def run!
      text_model  = SiteSetting.digest_campaigns_gemini_text_model.to_s.strip
      image_model = SiteSetting.digest_campaigns_gemini_image_model.to_s.strip

      result_subjects   = [@subject_line_1, @subject_line_2, @subject_line_3]
      result_preheaders = [@preheader_line_1, @preheader_line_2]
      result_html       = @html_body
      text_prompt_used  = nil
      image_prompt_used = nil
      new_image_url     = nil

      if @do_text
        text_prompt_used = build_text_prompt
        text_json = call_gemini_text(text_model, text_prompt_used)
        parsed = JSON.parse(text_json)

        subjects = parsed["subject_titles_json"]
        if subjects.is_a?(Array) && subjects.length >= 1
          result_subjects[0] = subjects[0].to_s
          result_subjects[1] = subjects[1].to_s if subjects[1]
          result_subjects[2] = subjects[2].to_s if subjects[2]
        end

        preheaders = parsed["preheaders_json"]
        if preheaders.is_a?(Array) && preheaders.length >= 1
          result_preheaders[0] = preheaders[0].to_s
          result_preheaders[1] = preheaders[1].to_s if preheaders[1]
        end

        result_html = parsed["html"].to_s if parsed["html"].present?
      end

      if @do_image
        subjects_for_prompt   = result_subjects.reject(&:blank?)
        preheaders_for_prompt = result_preheaders.reject(&:blank?)
        html_for_prompt       = result_html.present? ? result_html : @html_body

        image_prompt_used = build_image_prompt(subjects_for_prompt, preheaders_for_prompt, html_for_prompt)
        image_data = call_gemini_image(image_model, image_prompt_used)

        if image_data
          new_image_url = upload_image_to_discourse(image_data[:bytes], image_data[:mime_type])
          result_html   = replace_first_image_in_html(result_html, new_image_url) if new_image_url.present?
        end
      end

      save_to_db(
        text_model: text_model, image_model: image_model,
        text_prompt: text_prompt_used, image_prompt: image_prompt_used,
        result_subjects: result_subjects, result_preheaders: result_preheaders,
        result_html: result_html, result_html_with_image: @do_image ? result_html : nil,
        new_image_discourse_url: new_image_url
      )

      {
        subject_line_1:   result_subjects[0].to_s,
        subject_line_2:   result_subjects[1].to_s,
        subject_line_3:   result_subjects[2].to_s,
        preheader_line_1: result_preheaders[0].to_s,
        preheader_line_2: result_preheaders[1].to_s,
        html_body:        result_html.to_s
      }
    end

    private

    # ─── Prompt builders ────────────────────────────────────────────

    def build_text_prompt
      subjects_list = [@subject_line_1, @subject_line_2, @subject_line_3]
        .each_with_index.map { |s, i| "#{i + 1}. #{s}" unless s.blank? }
        .compact.join("\n")

      preheaders_list = [@preheader_line_1, @preheader_line_2]
        .each_with_index.map { |p, i| "#{i + 1}. #{p}" unless p.blank? }
        .compact.join("\n")

      prompt = <<~PROMPT
        You are an expert email copywriter. You are given an existing HTML marketing email with its subject lines and preheader text.

        TASK: Rewrite this email keeping the same general topic, tone, and overall section structure. Produce a fresh version with new copy — different wording, different angle, but same emotional territory.

        CURRENT EMAIL:
        Subject lines:
        #{subjects_list.presence || "(none)"}

        Preheader lines:
        #{preheaders_list.presence || "(none)"}

        HTML body:
        #{@html_body}

        OUTPUT RULES:
        - Return ONLY valid JSON (no markdown fences, no code blocks, no explanation before or after)
        - Always return exactly 3 subject lines and exactly 2 preheader lines, even if originals are blank
        - Rewrite visible copy only — keep the same HTML section order and structure
        - Keep ALL image src attributes unchanged (same URLs)
        - Keep ALL link hrefs unchanged
        - Keep ALL inline CSS styles unchanged
        - Do NOT add or remove HTML sections

      PROMPT

      if @text_note.present?
        prompt += "ADDITIONAL INSTRUCTIONS:\n#{@text_note}\n\n"
      end

      prompt += <<~FORMAT
        REQUIRED JSON FORMAT (return this and nothing else):
        {
          "subject_titles_json": ["subject 1", "subject 2", "subject 3"],
          "preheaders_json": ["preheader 1", "preheader 2"],
          "html": "full rewritten HTML"
        }
      FORMAT

      prompt
    end

    def build_image_prompt(subjects, preheaders, html)
      html_snippet = html.to_s[0, HTML_TRUNCATE_FOR_IMAGE_PROMPT]

      prompt = <<~PROMPT
        Create ONE high-converting YouTube thumbnail style hero image for a marketing email.

        STYLE: YouTube thumbnail — bold, eye-catching, high contrast, immediately compelling on mobile.
        - Include a clear play-button cue: simple triangle inside a semi-transparent circular button
        - One dominant focal point and one clear visual story
        - Text overlay is allowed (max 10 words, curiosity-driven)
        - No product packaging, no device mockups, no screenshot or app UI style
        - No watermarks, no browser chrome, no fake interfaces

        EMAIL CONTEXT:
        Subject lines:
        #{subjects.map.with_index(1) { |s, i| "#{i}. #{s}" }.join("\n")}

        Preheader:
        #{preheaders.map.with_index(1) { |p, i| "#{i}. #{p}" }.join("\n")}

        Email content (first #{HTML_TRUNCATE_FOR_IMAGE_PROMPT} chars of HTML):
        #{html_snippet}

      PROMPT

      if @image_note.present?
        prompt += "ADDITIONAL INSTRUCTIONS:\n#{@image_note}\n\n"
      end

      prompt
    end

    # ─── Gemini API calls ────────────────────────────────────────────

    def call_gemini_text(model, prompt)
      body = {
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: {
          temperature: 0.7,
          maxOutputTokens: 60_000,
          responseMimeType: "application/json"
        }
      }

      response_body = gemini_post(model, body, timeout: 300)
      extract_text_from_gemini_response(JSON.parse(response_body))
    end

    def call_gemini_image(model, prompt)
      body = {
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: {
          responseModalities: ["IMAGE"],
          imageConfig: { aspectRatio: "16:9", imageSize: "1K" }
        }
      }

      response_body = gemini_post(model, body, timeout: 300)
      extract_image_from_gemini_response(JSON.parse(response_body))
    end

    def gemini_post(model, body, timeout: 120)
      uri = URI("#{GEMINI_BASE_URL}/#{URI.encode_uri_component(model)}:generateContent")

      http             = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl     = true
      http.read_timeout = timeout
      http.open_timeout = 60

      req                  = Net::HTTP::Post.new(uri.request_uri)
      req["x-goog-api-key"] = @api_key
      req["Content-Type"]  = "application/json"
      req.body             = body.to_json

      response = http.request(req)

      unless response.is_a?(Net::HTTPSuccess)
        raise "Gemini API error #{response.code} for model #{model}: #{response.body.to_s[0, 500]}"
      end

      response.body
    end

    def extract_text_from_gemini_response(parsed)
      parts = parsed.dig("candidates", 0, "content", "parts") || []
      text = parts.map { |p| p["text"] }.compact.join("\n").strip
      raise "Gemini returned no text. promptFeedback=#{parsed["promptFeedback"]}" if text.blank?
      text
    end

    def extract_image_from_gemini_response(parsed)
      candidates = parsed["candidates"] || []
      candidates.each do |candidate|
        parts = candidate.dig("content", "parts") || []
        parts.each do |part|
          inline = part["inlineData"] || part["inline_data"]
          next unless inline
          mime = inline["mimeType"] || inline["mime_type"] || "image/png"
          data = inline["data"]
          next if data.blank?
          return { mime_type: mime, bytes: Base64.decode64(data) }
        end
      end
      nil
    end

    # ─── Discourse image upload ───────────────────────────────────────

    def upload_image_to_discourse(bytes, mime_type)
      ext = case mime_type.to_s.downcase
            when /png/  then "png"
            when /webp/ then "webp"
            when /gif/  then "gif"
            else "jpg"
            end

      tmp = Tempfile.new(["digest_regen_image", ".#{ext}"])
      tmp.binmode
      tmp.write(bytes)
      tmp.rewind

      upload = UploadCreator.new(tmp, "regen_email_image.#{ext}", type: "composer")
                            .create_for(Discourse.system_user.id)
      tmp.close
      tmp.unlink

      raise "Discourse image upload failed: #{upload.errors.full_messages.join(', ')}" unless upload.persisted?

      UrlHelper.cook_url(upload.url)
    end

    # ─── HTML image replacement ───────────────────────────────────────

    # Finds the first <img> with a real http/https src URL and replaces it with new_url.
    # The surrounding <a> link (if any) is left intact so the click destination is preserved.
    def replace_first_image_in_html(html, new_url)
      return html if html.blank? || new_url.blank?

      replaced = false
      result = html.gsub(/<img\b([^>]*?)src\s*=\s*(["'])(https?:\/\/[^"']+)\2([^>]*?)>/i) do |match|
        next match if replaced
        before = $1
        quote  = $2
        after  = $4
        replaced = true
        "<img#{before}src=#{quote}#{new_url}#{quote}#{after}>"
      end
      result
    end

    # ─── Persistence ─────────────────────────────────────────────────

    def save_to_db(
      text_model:, image_model:,
      text_prompt:, image_prompt:,
      result_subjects:, result_preheaders:,
      result_html:, result_html_with_image:,
      new_image_discourse_url:
    )
      DB.exec(<<~SQL,
        INSERT INTO digest_campaign_regenerations (
          source_subject_line_1, source_subject_line_2, source_subject_line_3,
          source_preheader_line_1, source_preheader_line_2, source_html,
          do_text, do_image, text_note, image_note,
          text_prompt,
          result_subject_line_1, result_subject_line_2, result_subject_line_3,
          result_preheader_line_1, result_preheader_line_2,
          result_html,
          image_prompt, new_image_discourse_url, result_html_with_image,
          gemini_text_model, gemini_image_model,
          created_at
        ) VALUES (
          :s1, :s2, :s3,
          :p1, :p2, :src_html,
          :do_text, :do_image, :text_note, :image_note,
          :text_prompt,
          :rs1, :rs2, :rs3,
          :rp1, :rp2,
          :result_html,
          :image_prompt, :new_image_url, :result_html_with_image,
          :text_model, :image_model,
          NOW()
        )
      SQL
        s1:                   @subject_line_1,
        s2:                   @subject_line_2,
        s3:                   @subject_line_3,
        p1:                   @preheader_line_1,
        p2:                   @preheader_line_2,
        src_html:             @html_body[0, 200_000],
        do_text:              @do_text,
        do_image:             @do_image,
        text_note:            @text_note,
        image_note:           @image_note,
        text_prompt:          text_prompt.to_s[0, 200_000],
        rs1:                  result_subjects[0].to_s,
        rs2:                  result_subjects[1].to_s,
        rs3:                  result_subjects[2].to_s,
        rp1:                  result_preheaders[0].to_s,
        rp2:                  result_preheaders[1].to_s,
        result_html:          result_html.to_s[0, 200_000],
        image_prompt:         image_prompt.to_s[0, 200_000],
        new_image_url:        new_image_discourse_url.to_s,
        result_html_with_image: result_html_with_image.to_s[0, 200_000],
        text_model:           text_model,
        image_model:          image_model
      )
    rescue => e
      Rails.logger.warn("[DigestCampaigns] Failed to save regeneration to DB: #{e.message}")
    end
  end
end
