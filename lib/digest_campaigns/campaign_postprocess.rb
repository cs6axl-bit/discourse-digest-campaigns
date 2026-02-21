# frozen_string_literal: true

require "uri"
require "base64"
require "securerandom"

begin
  require "nokogiri"
rescue LoadError
  Nokogiri = nil
end

module ::DigestCampaigns
  module CampaignPostprocess
    # =========================
    # CONFIG (inline; adjust if needed)
    # =========================
    ENABLE_LINK_REWRITE = true

    # Rewrite links inside post bodies (excerpts) to /content?u=<base64url(url)>
    ENABLE_CONTENT_REDIRECTOR_FOR_POST_BODY_LINKS = true
    CONTENT_REDIRECTOR_PATH  = "/content"
    CONTENT_REDIRECTOR_PARAM = "u"

    # Append tracking params to FINAL destination URL BEFORE encoding (post-body links only)
    ENABLE_APPEND_TRACKING_PARAMS_TO_POST_BODY_LINKS = true
    TRACKING_PARAMS_TO_APPEND = ["aff_sub2", "subid2"]

    # Also append email_id as a separate param on the FINAL destination URL (pre-encoding)
    ENABLE_APPEND_EMAIL_ID_TO_POST_BODY_LINKS = true
    POST_BODY_EMAIL_ID_PARAM = "email_id"

    ENABLE_TRIM_HTML_PART = true
    HTML_MAX_CHARS        = 300

    ENABLE_TRIM_TEXT_PART = true
    TEXT_MAX_CHARS        = 300

    # If true, when we trim an excerpt we ALSO remove any trailing HTML nodes
    # (images, tables, oneboxes, etc.) after the cut point.
    ENABLE_TRIM_HTML_REMOVE_TRAILING_NODES = true

    HTML_EXCERPT_SELECTORS = [
      ".digest-post-excerpt",
      ".post-excerpt",
      ".excerpt",
      ".topic-excerpt",
      "div[itemprop='articleBody']"
    ]

    NEVER_TOUCH_HREF_SUBSTRINGS = [
      "/email/unsubscribe",
      "/my/preferences"
    ]

    TEXT_TOPIC_URL_REGEX = %r{(^|\s)(https?://\S+)?/t/[^ \n]+}i

    TEXT_NEVER_TRIM_KEYWORDS = [
      "unsubscribe",
      "/email/unsubscribe",
      "preferences",
      "/my/preferences"
    ]

    POPULAR_POSTS_MARKERS = [
      "popular posts",
      "popular topics"
    ]

    # =========================
    # Public entrypoint
    # =========================
    def self.process!(message, user, email_id)
      return if message.nil?
      process_html_part!(message, user, email_id)
      trim_digest_text_part!(message)
    end

    def self.generate_email_id
      SecureRandom.random_number(10**20).to_s.rjust(20, "0")
    end

    def self.encoded_email(user)
      email = user&.email.to_s
      return "" if email.empty?
      Base64.urlsafe_encode64(email, padding: false)
    end

    def self.normalize_spaces(s)
      s.to_s.gsub(/\s+/, " ").strip
    end

    def self.contains_any?(haystack, needles)
      h = haystack.to_s
      needles.any? { |n| h.include?(n) }
    end

    def self.smart_trim_plain(text, max_chars)
      raw = text.to_s.gsub(/\r\n?/, "\n")

      nl = raw.index("\n")
      linebreak_forced = nl && nl > 0 && nl < max_chars

      if linebreak_forced
        kept = raw[0, nl]
        kept_norm = normalize_spaces(kept)
        return kept_norm if kept_norm.empty?
        return kept_norm.end_with?("…") ? kept_norm : (kept_norm + "…")
      end

      full_norm = normalize_spaces(raw)
      return full_norm if full_norm.length <= max_chars

      limit = [max_chars - 1, 0].max
      cut = full_norm[0, limit]

      if (idx = cut.rindex(/\s/))
        cut = cut[0, idx]
      end

      cut = cut.rstrip
      return cut if cut.empty?
      cut.end_with?("…") ? cut : (cut + "…")
    rescue
      normalize_spaces(text)
    end

    def self.base64url_encode(s)
      Base64.urlsafe_encode64(s.to_s, padding: false)
    rescue
      ""
    end

    def self.make_content_redirector_url(final_url, base)
      token = base64url_encode(final_url)
      return nil if token.to_s.empty?
      "#{base}#{CONTENT_REDIRECTOR_PATH}?#{CONTENT_REDIRECTOR_PARAM}=#{token}"
    end

    def self.absolute_url_from_href(href, base)
      h = href.to_s.strip
      return nil if h.empty?
      return (base + h) if h.start_with?("/")
      h
    end

    def self.http_url?(url)
      u = URI.parse(url)
      u.is_a?(URI::HTTP) || u.is_a?(URI::HTTPS)
    rescue
      false
    end

    # =========================
    # Topic ID extraction for excerpt context
    # =========================
    def self.extract_topic_id_from_href(href, base)
      h = href.to_s
      return nil if h.empty?
      return nil unless h.include?("/t/")

      path =
        if h.start_with?("/")
          h
        elsif h.start_with?(base)
          h.sub(base, "")
        else
          h
        end

      m = path.match(%r{/t/(?:[^/]+/)?(\d+)}i)
      m ? m[1] : nil
    rescue
      nil
    end

    def self.topic_id_context_for_excerpt(node, base)
      return nil unless node

      begin
        anc = node.at_xpath("ancestor-or-self::*[@data-topic-id or @data-topicid or @topic-id][1]")
        if anc
          v = anc["data-topic-id"] || anc["data-topicid"] || anc["topic-id"]
          vv = v.to_s.strip
          return vv if vv.match?(/^\d+$/)
        end
      rescue
      end

      begin
        a = node.at_xpath("preceding::p[contains(concat(' ', normalize-space(@class), ' '), ' digest-topic-name ')][1]//a[@href][1]")
        if a && a["href"]
          id = extract_topic_id_from_href(a["href"], base)
          return id if id
        end
      rescue
      end

      begin
        a2 = node.at_xpath("preceding::a[contains(@href, '/t/')][1]")
        if a2 && a2["href"]
          id2 = extract_topic_id_from_href(a2["href"], base)
          return id2 if id2
        end
      rescue
      end

      nil
    end

    def self.user_topic_email_value(user_id, topic_id_context, email_id)
      uid = user_id.to_s
      return "" if uid.empty?
      tid = topic_id_context.to_s
      eid = email_id.to_s
      return "" if eid.empty?
      "#{uid}-#{tid}-#{eid}"
    end

    # Normalize URLs like ".../3/&subid=foo" into query string
    def self.normalize_query_stuck_in_path!(uri)
      return false unless uri
      return false if uri.query && !uri.query.to_s.empty?

      path = uri.path.to_s
      return false if path.empty?

      m = path.match(%r{^(.*?)/&([^#?]+)$})
      return false unless m

      tail = m[2].to_s
      return false unless tail.include?("=")

      uri.path = m[1].to_s + "/"
      uri.query = tail
      true
    rescue
      false
    end

    def self.append_tracking_params(url, user_id, topic_id_context, email_id)
      return url if url.to_s.empty?

      uri = URI.parse(url)
      return url unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      normalize_query_stuck_in_path!(uri)

      params = URI.decode_www_form(uri.query || "")

      if ENABLE_APPEND_EMAIL_ID_TO_POST_BODY_LINKS
        k = POST_BODY_EMAIL_ID_PARAM.to_s
        if !k.empty? && email_id.to_s != "" && !params.any? { |kk, _| kk == k }
          params << [k, email_id.to_s]
        end
      end

      val = user_topic_email_value(user_id, topic_id_context, email_id)

      if val.empty?
        uri.query = URI.encode_www_form(params)
        return uri.to_s
      end

      TRACKING_PARAMS_TO_APPEND.each do |k|
        kk = k.to_s
        next if kk.empty?
        next if params.any? { |k2, _| k2 == kk }
        params << [kk, val]
      end

      uri.query = URI.encode_www_form(params)
      uri.to_s
    rescue
      url
    end

    # =========================
    # Popular Posts boundary + topic counting (skip trim if only 1 topic)
    # =========================
    def self.node_text_matches_popular?(node)
      t = normalize_spaces(node&.text).downcase
      return false if t.empty?
      POPULAR_POSTS_MARKERS.any? { |m| t.include?(m) }
    rescue
      false
    end

    def self.find_popular_marker_node(doc)
      return nil unless doc
      doc.css("h1,h2,h3,h4,h5,h6,strong,b,td,th,p,div,span").find { |n| node_text_matches_popular?(n) }
    rescue
      nil
    end

    def self.before_marker?(node, marker)
      return true unless marker
      node < marker
    rescue
      true
    end

    def self.primary_topic_count_before_popular(doc)
      return nil unless doc
      base   = Discourse.base_url
      marker = find_popular_marker_node(doc)

      keys = []

      doc.css("p.digest-topic-name").each do |p|
        next unless before_marker?(p, marker)

        a = p.at_css("a[href]")
        id = a ? extract_topic_id_from_href(a["href"], base) : nil

        title = normalize_spaces(p.text)
        if id
          keys << "id:#{id}"
        elsif !title.empty?
          keys << "t:#{title}"
        end
      end

      keys = keys.compact.uniq
      return keys.size if keys.any?

      ids = []
      doc.css("a[href]").each do |a|
        next unless before_marker?(a, marker)
        id = extract_topic_id_from_href(a["href"], base)
        ids << id if id
      end

      ids = ids.compact.uniq
      return ids.size if ids.any?

      nil
    rescue
      nil
    end

    # =========================
    # HTML trimming helpers
    # =========================
    def self.text_before_node(root, stop_node)
      out = +""
      root.traverse do |n|
        break if n == stop_node
        if n.text?
          out << n.text
          out << " "
        end
      end
      out
    rescue
      ""
    end

    def self.has_content_after_boundary?(boundary, root)
      cur = boundary
      while cur && cur != root
        sib = cur.next_sibling
        while sib
          if sib.element?
            return true
          elsif sib.text?
            return true unless normalize_spaces(sib.text).empty?
          end
          sib = sib.next_sibling
        end
        cur = cur.parent
      end
      false
    rescue
      true
    end

    def self.remove_following_siblings_up_to_root!(boundary, root)
      cur = boundary
      while cur && cur != root
        cur.xpath("following-sibling::node()").each(&:remove)
        cur = cur.parent
      end
      true
    rescue
      false
    end

    def self.end_node_for_kept_region(boundary)
      return boundary unless boundary
      last_desc = boundary.xpath(".//node()").to_a.last
      last_desc || boundary
    rescue
      boundary
    end

    def self.remove_text_nodes_after_end!(root, end_node)
      return false unless root && end_node
      root.xpath(".//text()[not(ancestor::script) and not(ancestor::style)]").each do |tn|
        next unless tn > end_node
        tn.remove
      end
      true
    rescue
      false
    end

    def self.trim_html_at_first_line_break!(node, max_chars)
      return false unless node

      br = node.at_css("br")
      if br
        before_len = normalize_spaces(text_before_node(node, br)).length
        if before_len > 0 && before_len < max_chars && has_content_after_boundary?(br, node)
          if ENABLE_TRIM_HTML_REMOVE_TRAILING_NODES
            remove_following_siblings_up_to_root!(br, node)
          else
            remove_text_nodes_after_end!(node, br)
          end
          br.remove
          return true
        end
      end

      boundary = node.at_css("p,li")
      if boundary
        kept_len = normalize_spaces(boundary.text).length
        if kept_len > 0 && kept_len < max_chars && has_content_after_boundary?(boundary, node)
          if ENABLE_TRIM_HTML_REMOVE_TRAILING_NODES
            remove_following_siblings_up_to_root!(boundary, node)
          else
            end_node = end_node_for_kept_region(boundary)
            remove_text_nodes_after_end!(node, end_node)
          end
          return true
        end
      end

      false
    rescue
      false
    end

    def self.trim_html_node_in_place!(node, max_chars)
      break_trimmed = trim_html_at_first_line_break!(node, max_chars)

      full_norm = normalize_spaces(node.text.to_s)
      return break_trimmed if full_norm.length <= max_chars

      text_nodes = node.xpath(".//text()[not(ancestor::script) and not(ancestor::style)]").to_a
      return break_trimmed if text_nodes.empty?

      budget = max_chars
      trimming_started = false

      text_nodes.each_with_index do |tn, idx|
        raw  = tn.text.to_s
        norm = normalize_spaces(raw)
        next if norm.empty?

        if !trimming_started
          if norm.length <= budget
            budget -= norm.length
            next
          end

          tn.content = smart_trim_plain(raw, budget)
          trimming_started = true

          if ENABLE_TRIM_HTML_REMOVE_TRAILING_NODES
            remove_following_siblings_up_to_root!(tn, node)
          else
            text_nodes[(idx + 1)..-1].to_a.each(&:remove)
          end

          break
        else
          tn.remove
        end
      end

      trimming_started || break_trimmed
    rescue
      false
    end

    # =========================
    # HTML processing
    # =========================
    def self.process_html_part!(message, user, email_id)
      return if message.nil?
      return unless ENABLE_LINK_REWRITE || ENABLE_TRIM_HTML_PART || ENABLE_CONTENT_REDIRECTOR_FOR_POST_BODY_LINKS

      html_part =
        if message.respond_to?(:html_part) && message.html_part
          message.html_part
        else
          message
        end

      body = html_part.body&.decoded
      return if body.nil? || body.empty?

      base = Discourse.base_url

      if !Nokogiri
        # Fail open: do nothing rather than regex-mangling on campaigns
        return
      end

      dayofweek_val = encoded_email(user)
      doc = Nokogiri::HTML(body)
      changed = false

      primary_topic_count = primary_topic_count_before_popular(doc)
      skip_trim = (primary_topic_count == 1)
      do_trim = primary_topic_count.nil? ? true : (primary_topic_count > 1)

      # 1) rewrite INTERNAL links: add isdigest/u/dayofweek/email_id
      if ENABLE_LINK_REWRITE
        doc.css("a[href]").each do |a|
          href = a["href"].to_s.strip
          next if href.empty?
          next if href.start_with?("mailto:", "tel:", "sms:", "#")

          is_relative = href.start_with?("/")
          is_internal = href.start_with?(base)
          next unless is_relative || is_internal

          next if contains_any?(href, NEVER_TOUCH_HREF_SUBSTRINGS)

          begin
            uri = URI.parse(is_relative ? (base + href) : href)
          rescue URI::InvalidURIError
            next
          end

          params = URI.decode_www_form(uri.query || "")
          added = false

          unless params.any? { |k, _| k == "isdigest" }
            params << ["isdigest", "1"]
            added = true
          end

          unless params.any? { |k, _| k == "u" }
            params << ["u", user.id.to_s]
            added = true
          end

          if !dayofweek_val.empty? && !params.any? { |k, _| k == "dayofweek" }
            params << ["dayofweek", dayofweek_val]
            added = true
          end

          if email_id && !email_id.empty? && !params.any? { |k, _| k == "email_id" }
            params << ["email_id", email_id]
            added = true
          end

          next unless added

          uri.query = URI.encode_www_form(params)
          a["href"] = uri.to_s
          changed = true
        end
      end

      # 2) rewrite links INSIDE excerpt bodies to /content?u=base64url(final_url)
      if ENABLE_CONTENT_REDIRECTOR_FOR_POST_BODY_LINKS
        excerpt_nodes =
          HTML_EXCERPT_SELECTORS
            .flat_map { |sel| doc.css(sel).to_a }
            .uniq

        excerpt_nodes.each do |node|
          topic_ctx = topic_id_context_for_excerpt(node, base)

          node.css("a[href]").each do |a|
            href = a["href"].to_s.strip
            next if href.empty?
            next if href.start_with?("mailto:", "tel:", "sms:", "#")
            next if contains_any?(href, NEVER_TOUCH_HREF_SUBSTRINGS)

            abs0 = absolute_url_from_href(href, base)
            next if abs0.nil?
            next unless http_url?(abs0)

            # skip if already /content
            begin
              u0 = URI.parse(abs0)
              b0 = URI.parse(base)
              if u0.host == b0.host && u0.path == CONTENT_REDIRECTOR_PATH
                next
              end
            rescue
            end

            final_dest =
              if ENABLE_APPEND_TRACKING_PARAMS_TO_POST_BODY_LINKS
                append_tracking_params(abs0, user.id, topic_ctx, email_id)
              else
                abs0
              end

            redirect_abs = make_content_redirector_url(final_dest, base)
            next if redirect_abs.nil?

            a["href"] = redirect_abs
            changed = true
          end
        end
      end

      # 3) HTML excerpt trimming
      if ENABLE_TRIM_HTML_PART && !skip_trim && do_trim
        nodes =
          HTML_EXCERPT_SELECTORS
            .flat_map { |sel| doc.css(sel).to_a }
            .uniq

        nodes.each do |node|
          begin
            hrefs = node.css("a[href]").map { |x| x["href"].to_s }
            next if hrefs.any? { |h| contains_any?(h, NEVER_TOUCH_HREF_SUBSTRINGS) }
          rescue
            next
          end

          if trim_html_node_in_place!(node, HTML_MAX_CHARS)
            changed = true
          end
        end
      end

      html_part.body = doc.to_html if changed
    rescue => e
      Rails.logger.warn("DigestCampaigns CampaignPostprocess HTML failed: #{e.class}: #{e.message}")
      nil
    end

    # =========================
    # TEXT trimming (topic-body-only)
    # =========================
    def self.count_topics_in_text_blocks(blocks)
      cutoff = blocks.find_index do |b|
        t = normalize_spaces(b).downcase
        POPULAR_POSTS_MARKERS.any? { |m| t.include?(m) }
      end

      scoped_text = cutoff ? blocks[0...cutoff].join("\n\n") : blocks.join("\n\n")
      ids = scoped_text.scan(%r{/t/(?:[^/\s]+/)?(\d+)}i).flatten.uniq
      ids.size
    rescue
      999
    end

    def self.trim_digest_text_part!(message)
      return if message.nil?
      return unless ENABLE_TRIM_TEXT_PART
      return unless message.respond_to?(:text_part) && message.text_part

      tp = message.text_part
      text = tp.body&.decoded
      return if text.nil? || text.empty?

      t = text.to_s.gsub(/\r\n?/, "\n")
      blocks = t.split(/\n{2,}/)

      topic_count = count_topics_in_text_blocks(blocks)
      return if topic_count <= 1

      changed = false

      blocks.each_with_index do |blk, i|
        b = blk.to_s
        next if b.strip.empty?

        b_down = b.downcase
        next if TEXT_NEVER_TRIM_KEYWORDS.any? { |kw| b_down.include?(kw.downcase) }

        prev = (i > 0) ? blocks[i - 1].to_s : ""
        prev_has_topic_url = !!(prev =~ TEXT_TOPIC_URL_REGEX)
        next unless prev_has_topic_url

        b2 = b.to_s.gsub(/\r\n?/, "\n")
        nl = b2.index("\n")
        linebreak_forced = nl && nl > 0 && nl < TEXT_MAX_CHARS

        norm_len = normalize_spaces(b2).length
        need_trim = linebreak_forced || (norm_len > TEXT_MAX_CHARS)
        next unless need_trim

        blocks[i] = smart_trim_plain(b2, TEXT_MAX_CHARS)
        changed = true
      end

      tp.body = blocks.join("\n\n") if changed
    rescue => e
      Rails.logger.warn("DigestCampaigns CampaignPostprocess TEXT failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
