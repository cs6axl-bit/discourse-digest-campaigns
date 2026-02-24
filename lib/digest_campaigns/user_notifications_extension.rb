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
  # ============================================================
  # Campaign-only port of: digest-append3-links-and-trim-excerpt v1.7.9
  # PLUS: campaign-only excerpt trimming control:
  #   - digest_campaigns_trim_excerpts_enabled (bool)
  #   - digest_campaigns_trim_excerpts_ignore_first_n_topics (int, default 1)
  #
  # PLUS: campaign-only subject + preheader:
  #   - subject = first topic title (smart-trimmed to 200 with …)
  #   - preheader = first 200 chars of first topic body (smart-trimmed with …)
  #
  # PLUS: remove "Since your last visit" / counts for campaigns:
  #   - @since = nil
  #   - @counts = []
  # ============================================================
  module DigestAppendData
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
    # If false, we remove ONLY trailing text nodes (images/objects may remain).
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

    # Heading text that marks the start of the "Popular Posts" section.
    POPULAR_POSTS_MARKERS = [
      "popular posts",
      "popular topics"
    ]

    # ============================================================
    # Helpers
    # ============================================================

    # CHANGED:
    # email_id is now ALWAYS campaign-shaped (20 digits):
    #   "0000" + <campaign_id_digits_or_0> + "000" + <random_digits>
    #
    # Rules guaranteed:
    #   - starts with 4 zeros
    #   - contains another 3 consecutive zeros somewhere
    #   - has at least 7 zeros total (prefix + mid)
    #
    # If campaign_id missing/invalid -> uses "0" (so tests/drafts still follow the rules)
    # If campaign_id too long -> keep last digits to fit 20 total.
    def self.generate_email_id(campaign_id: nil)
      total_len = 20
      prefix = "0000"
      mid    = "000"

      cid = campaign_id.to_s.gsub(/\D+/, "") # digits only
      cid = "0" if cid.empty?

      # Must leave at least 1 random digit
      max_cid_len = total_len - (prefix.length + mid.length + 1)
      max_cid_len = 1 if max_cid_len < 1

      if cid.length > max_cid_len
        cid = cid[-max_cid_len, max_cid_len] # keep last digits
      end

      remaining = total_len - (prefix.length + cid.length + mid.length)
      remaining = 1 if remaining < 1

      rnd = SecureRandom.random_number(10**remaining).to_s.rjust(remaining, "0")
      (prefix + cid + mid + rnd)
    rescue
      # keep format even on failure
      ("0000" + "0" + "000" + SecureRandom.random_number(10**12).to_s.rjust(12, "0"))[0, 20]
    end

    def self.email_id_debug_enabled?
      SiteSetting.digest_campaigns_email_id_debug_enabled
    rescue
      false
    end

    def self.email_id_dlog(msg)
      return unless email_id_debug_enabled?
      Rails.logger.error(msg)
    rescue
      # ignore
    end

    def self.encoded_email(user)
      email = user&.email.to_s
      return "" if email.empty?
      Base64.urlsafe_encode64(email, padding: false)
    end

    # IMPORTANT: collapse ALL whitespace (including newlines) into spaces
    def self.normalize_spaces(s)
      s.to_s.gsub(/\s+/, " ").strip
    end

    def self.contains_any?(haystack, needles)
      h = haystack.to_s
      needles.any? { |n| h.include?(n) }
    end

    # Trim to min(max_chars, first newline if it occurs before max_chars).
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

    # ============================================================
    # Domain swapping (post-process, after all other logic)
    # ============================================================

    def self.discourse_hostname
      h = nil

      begin
        h = Discourse.current_hostname
      rescue
        h = nil
      end

      if h.to_s.strip.blank?
        begin
          h = URI.parse(Discourse.base_url).host
        rescue
          h = nil
        end
      end

      if h.to_s.strip.blank?
        begin
          h = SiteSetting.force_hostname
        rescue
          h = nil
        end
      end

      h.to_s.strip
    rescue
      ""
    end

    def self.domain_swap_enabled?
      SiteSetting.digest_campaigns_domain_swap_enabled &&
        discourse_hostname.present? &&
        SiteSetting.digest_campaigns_domain_swap_targets.to_s.strip.present?
    rescue
      false
    end

    def self.domain_swap_html_links_enabled?
      SiteSetting.digest_campaigns_domain_swap_html_links_enabled
    rescue
      false
    end

    def self.domain_swap_text_links_enabled?
      SiteSetting.digest_campaigns_domain_swap_text_links_enabled
    rescue
      false
    end

    def self.domain_swap_everywhere_enabled?
      SiteSetting.digest_campaigns_domain_swap_everywhere_enabled
    rescue
      false
    end

    def self.domain_swap_headers_enabled?
      SiteSetting.digest_campaigns_domain_swap_headers_enabled
    rescue
      false
    end

    def self.domain_swap_message_id_enabled?
      SiteSetting.digest_campaigns_domain_swap_message_id_enabled
    rescue
      false
    end

    def self.parse_target_domains
      raw = SiteSetting.digest_campaigns_domain_swap_targets.to_s
      raw
        .split(/[\s,]+/)
        .map { |x| x.to_s.strip }
        .reject(&:blank?)
        .map { |h| h.sub(%r{\Ahttps?://}i, '').sub(%r{\A//}i, '').sub(%r{/.*\z}, '') }
        .reject(&:blank?)
        .uniq
    rescue
      []
    end

    def self.pick_target_domain(domains)
      ds = Array(domains).reject(&:blank?)
      return nil if ds.empty?
      ds[SecureRandom.random_number(ds.length)]
    rescue
      nil
    end

    def self.host_matches_origin?(host, origin)
      h = host.to_s.downcase
      o = origin.to_s.downcase
      return false if h.blank? || o.blank?
      h == o
    end

    def self.swap_url_host(url, origin_host, target_host)
      s = url.to_s
      return s if s.blank?
      return s if target_host.to_s.blank? || origin_host.to_s.blank?
      return s if s.start_with?("mailto:", "tel:", "sms:")

      protocol_relative = s.start_with?("//")
      parsed = nil
      begin
        parsed = URI.parse(protocol_relative ? ("https:" + s) : s)
      rescue
        return s
      end

      return s unless parsed.is_a?(URI::HTTP) || parsed.is_a?(URI::HTTPS)
      return s unless host_matches_origin?(parsed.host, origin_host)

      parsed.host = target_host.to_s
      out = parsed.to_s
      protocol_relative ? out.sub(%r{\Ahttps?:}i, "") : out
    rescue
      s
    end

    URL_LIKE_REGEX = %r{(?:(?:https?:)?//[^\s<>"]+)}i

    def self.swap_domains_in_text(text, origin_host, target_host)
      t = text.to_s
      return t if t.blank?
      t.gsub(URL_LIKE_REGEX) do |m|
        swap_url_host(m, origin_host, target_host)
      end
    rescue
      text.to_s
    end

    # Replace raw occurrences of the origin domain token (not just URLs).
    # Token-bounded, so we don't rewrite parts of other domains.
    def self.swap_domain_literal(text, origin_host, target_host)
      s = text.to_s
      return s if s.blank?
      return s if target_host.to_s.blank? || origin_host.to_s.blank?

      escaped = Regexp.escape(origin_host.to_s)
      re = /(?i)(?<![A-Za-z0-9.-])#{escaped}(?![A-Za-z0-9.-])/i
      s.gsub(re, target_host.to_s)
    rescue
      text.to_s
    end

    def self.swap_message_id_header_value(value, origin_host, target_host)
      v = value.to_s
      return v if v.blank?
      return v if target_host.to_s.blank? || origin_host.to_s.blank?

      escaped = Regexp.escape(origin_host.to_s)
      v.gsub(/<([^<>]*?)@#{escaped}>/i) { "<#{$1}@#{target_host}>" }
    rescue
      value.to_s
    end

    def self.process_domain_swap!(message)
      return if message.nil?
      return unless domain_swap_enabled?

      origin = discourse_hostname
      origin = origin.sub(%r{\Ahttps?://}i, '').sub(%r{\A//}i, '').sub(%r{/.*\z}, '')

      targets = parse_target_domains
      target = pick_target_domain(targets)
      return if origin.blank? || target.blank?

      # ---- HTML part ----
      begin
        if Nokogiri && message.respond_to?(:html_part) && message.html_part
          hp = message.html_part
          html = hp.body&.decoded.to_s
          if html.present?
            doc = Nokogiri::HTML(html)
            changed = false

            # (A) Swap link hosts in attributes
            if domain_swap_html_links_enabled?
              doc.css("*[href], *[src]").each do |node|
                %w[href src].each do |attr|
                  v = node[attr].to_s
                  next if v.blank?
                  nv = swap_url_host(v, origin, target)
                  next if nv == v
                  node[attr] = nv
                  changed = true
                end
              end
            end

            # (B) Everywhere: also swap raw domain occurrences in visible text + style attrs
            if domain_swap_everywhere_enabled?
              doc.xpath("//text()").each do |tn|
                next unless tn
                parent = tn.parent
                next if parent && %w[script style noscript].include?(parent.name.to_s.downcase)
                old = tn.text.to_s
                next if old.blank?
                nw = swap_domain_literal(old, origin, target)
                next if nw == old
                tn.content = nw
                changed = true
              end

              doc.css("*[style]").each do |node|
                old = node["style"].to_s
                next if old.blank?
                nw = swap_domain_literal(old, origin, target)
                next if nw == old
                node["style"] = nw
                changed = true
              end
            end

            hp.body = doc.to_html if changed
          end
        end
      rescue => e
        Rails.logger.warn("digest-campaigns domain swap HTML failed: #{e.class}: #{e.message}")
      end

      # ---- Text part ----
      begin
        if message.respond_to?(:text_part) && message.text_part
          tp = message.text_part
          txt = tp.body&.decoded.to_s
          if txt.present?
            out = txt
            out = swap_domains_in_text(out, origin, target) if domain_swap_text_links_enabled?
            out = swap_domain_literal(out, origin, target) if domain_swap_everywhere_enabled?
            tp.body = out if out != txt
          end
        end
      rescue => e
        Rails.logger.warn("digest-campaigns domain swap TEXT failed: #{e.class}: #{e.message}")
      end

      # ---- Headers (FIX: rewrite existing header fields IN-PLACE to avoid duplicates) ----
      begin
        if domain_swap_headers_enabled? && message.respond_to?(:header) && message.header
          header_keys = %w[
            List-Unsubscribe
            List-Unsubscribe-Post
            List-Help
            List-Archive
            List-Post
            List-Id
            List-Owner
            Feedback-ID
          ]

          header_keys.each do |hk|
            fields = message.header.fields.select { |f| f.name.to_s.casecmp?(hk) }
            next if fields.empty?

            fields.each do |f|
              v = f.value.to_s
              next if v.blank?
              out = swap_domains_in_text(v, origin, target)
              out = swap_domain_literal(out, origin, target) if domain_swap_everywhere_enabled?
              next if out == v
              f.value = out
            end
          end
        end
      rescue => e
        Rails.logger.warn("digest-campaigns domain swap headers failed: #{e.class}: #{e.message}")
      end

      # ---- Message-ID header (FIX: value-only + in-place; supports Message-Id variants) ----
      begin
        if domain_swap_message_id_enabled? && message.respond_to?(:header) && message.header
          # IMPORTANT:
          # Mail/ActionMailer can treat Message-ID specially (lazy generation / normalization).
          # To prevent our swap from being overwritten, set BOTH:
          #  - message.message_id (attribute)
          #  - the actual header field value in-place

          # Force generation if Mail hasn't created it yet
          begin
            _ = message.message_id
          rescue
            # ignore
          end

          # Accept common casings/variants
          fields = message.header.fields.select do |f|
            n = f.name.to_s
            n.casecmp?("Message-ID") || n.casecmp?("Message-Id")
          end

          fields = [message.header["Message-ID"]].compact if fields.blank? && message.header["Message-ID"]

          fields.each do |f|
            v = f.respond_to?(:value) ? f.value.to_s : f.to_s
            next if v.blank?

            out = swap_message_id_header_value(v, origin, target)
            next if out == v

            # Set header field in-place
            if f.respond_to?(:value=)
              f.value = out
            else
              message.header["Message-ID"] = out
            end

            # Also set the attribute so later normalization doesn't revert it
            begin
              message.message_id = out
            rescue
              # ignore
            end
          end
        end
      rescue => e
        Rails.logger.warn("digest-campaigns domain swap Message-ID failed: #{e.class}: #{e.message}")
      end
    rescue => e
      Rails.logger.warn("digest-campaigns domain swap wrapper failed: #{e.class}: #{e.message}")
      nil
    end

    # ============================================================
    # Topic ID extraction
    # ============================================================

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

    # Try to infer "current digest topic id" for a given excerpt node.
    #
    # Strategy (cheap, robust):
    # 1) If any ancestor has data-topic-id / data-topicid / topic-id, use it.
    # 2) Look for the closest preceding p.digest-topic-name that has a /t/... link.
    # 3) As fallback, look for a preceding /t/... link anywhere (closest) and use that id.
    def self.topic_id_context_for_excerpt(node, base)
      return nil unless node

      # 1) ancestor attributes
      begin
        anc = node.at_xpath("ancestor-or-self::*[@data-topic-id or @data-topicid or @topic-id][1]")
        if anc
          v = anc["data-topic-id"] || anc["data-topicid"] || anc["topic-id"]
          vv = v.to_s.strip
          return vv if vv.match?(/^\d+$/)
        end
      rescue
        # ignore
      end

      # 2) closest preceding digest-topic-name
      begin
        a = node.at_xpath("preceding::p[contains(concat(' ', normalize-space(@class), ' '), ' digest-topic-name ')][1]//a[@href][1]")
        if a && a["href"]
          id = extract_topic_id_from_href(a["href"], base)
          return id if id
        end
      rescue
        # ignore
      end

      # 3) closest preceding /t/ anchor
      begin
        a2 = node.at_xpath("preceding::a[contains(@href, '/t/')][1]")
        if a2 && a2["href"]
          id2 = extract_topic_id_from_href(a2["href"], base)
          return id2 if id2
        end
      rescue
        # ignore
      end

      nil
    end

    # Build "userid-topicid-emailid" (topicid can be blank; keep the middle dash stable)
    def self.user_topic_email_value(user_id, topic_id_context, email_id)
      uid = user_id.to_s
      return "" if uid.empty?

      tid = topic_id_context.to_s # may be blank
      eid = email_id.to_s
      return "" if eid.empty?

      "#{uid}-#{tid}-#{eid}"
    end

    # ============================================================
    # URL normalization for broken affiliate URLs
    # ============================================================

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

    # ============================================================
    # Append tracking params (post-body links) BEFORE encoding into /content
    # ============================================================

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

    # ============================================================
    # "Popular Posts" boundary helpers (robust)
    # ============================================================

    def self.node_text_matches_popular?(node)
      t = normalize_spaces(node&.text).downcase
      return false if t.empty?
      POPULAR_POSTS_MARKERS.any? { |m| t.include?(m) }
    rescue
      false
    end

    def self.find_popular_marker_node(doc)
      return nil unless doc
      doc.css("h1,h2,h3,h4,h5,h6,strong,b,td,th,p,div,span").find do |n|
        node_text_matches_popular?(n)
      end
    rescue
      nil
    end

    def self.before_marker?(node, marker)
      return true unless marker
      node < marker
    rescue
      true
    end

    # ============================================================
    # Primary topic counting BEFORE Popular Posts (v1.6 fix)
    # ============================================================

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

    # ============================================================
    # HTML trimming helpers
    # ============================================================

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

      if break_trimmed && !trimming_started
        begin
          tn2 = node.xpath(".//text()[not(ancestor::script) and not(ancestor::style)]")
                    .to_a
                    .reverse
                    .find { |t| !normalize_spaces(t.text).empty? }
          if tn2
            s = tn2.text.to_s.rstrip
            tn2.content = s + "…" unless s.end_with?("…")
          end
        rescue
        end
      end

      trimming_started || break_trimmed
    rescue
      false
    end

    def self.protected_topic_ids_for_first_n(doc, ignore_n, base)
      ignore_n = ignore_n.to_i
      return {} if ignore_n <= 0
      ignore_n = 20 if ignore_n > 20

      marker = find_popular_marker_node(doc)

      excerpt_nodes =
        HTML_EXCERPT_SELECTORS
          .flat_map { |sel| doc.css(sel).to_a }
          .uniq

      seen = []
      excerpt_nodes.each do |node|
        next unless before_marker?(node, marker)

        tid = topic_id_context_for_excerpt(node, base).to_s
        next if tid.empty?
        next if seen.include?(tid)

        seen << tid
        break if seen.length >= ignore_n
      end

      out = {}
      seen.each { |tid| out[tid] = true }
      out
    rescue
      {}
    end

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
      return unless Nokogiri

      dayofweek_val = encoded_email(user)
      doc = Nokogiri::HTML(body)
      changed = false

      primary_topic_count = primary_topic_count_before_popular(doc)
      skip_trim_all = (primary_topic_count == 1)
      do_trim = primary_topic_count.nil? ? true : (primary_topic_count > 1)

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

          next unless uri.scheme.nil? || uri.scheme == "http" || uri.scheme == "https"

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

      trim_enabled = (SiteSetting.digest_campaigns_trim_excerpts_enabled && ENABLE_TRIM_HTML_PART)

      if trim_enabled && !skip_trim_all && do_trim
        ignore_n = SiteSetting.digest_campaigns_trim_excerpts_ignore_first_n_topics.to_i
        protected = protected_topic_ids_for_first_n(doc, ignore_n, base)

        nodes =
          HTML_EXCERPT_SELECTORS
            .flat_map { |sel| doc.css(sel).to_a }
            .uniq

        nodes.each do |node|
          ctx = topic_id_context_for_excerpt(node, base).to_s
          next if protected[ctx]

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
      Rails.logger.warn("digest-campaigns append+trim HTML process failed: #{e.class}: #{e.message}")
      nil
    end

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

    def self.extract_topic_id_from_text_block(block)
      m = block.to_s.match(%r{/t/(?:[^/\s]+/)?(\d+)}i)
      m ? m[1].to_s : ""
    rescue
      ""
    end

    def self.protected_topic_ids_for_text_first_n(blocks, ignore_n)
      ignore_n = ignore_n.to_i
      return {} if ignore_n <= 0
      ignore_n = 20 if ignore_n > 20

      cutoff = blocks.find_index do |b|
        t = normalize_spaces(b).downcase
        POPULAR_POSTS_MARKERS.any? { |m| t.include?(m) }
      end

      scoped = cutoff ? blocks[0...cutoff] : blocks

      seen = []
      scoped.each do |blk|
        tid = extract_topic_id_from_text_block(blk)
        next if tid.empty?
        next if seen.include?(tid)
        seen << tid
        break if seen.length >= ignore_n
      end

      out = {}
      seen.each { |tid| out[tid] = true }
      out
    rescue
      {}
    end

    def self.trim_digest_text_part!(message)
      return if message.nil?
      return unless SiteSetting.digest_campaigns_trim_excerpts_enabled
      return unless ENABLE_TRIM_TEXT_PART
      return unless message.respond_to?(:text_part) && message.text_part

      tp = message.text_part
      text = tp.body&.decoded
      return if text.nil? || text.empty?

      t = text.to_s.gsub(/\r\n?/, "\n")
      blocks = t.split(/\n{2,}/)

      topic_count = count_topics_in_text_blocks(blocks)
      return if topic_count <= 1

      ignore_n = SiteSetting.digest_campaigns_trim_excerpts_ignore_first_n_topics.to_i
      protected = protected_topic_ids_for_text_first_n(blocks, ignore_n)

      changed = false

      blocks.each_with_index do |blk, i|
        b = blk.to_s
        next if b.strip.empty?

        b_down = b.downcase
        next if TEXT_NEVER_TRIM_KEYWORDS.any? { |kw| b_down.include?(kw.downcase) }

        prev = (i > 0) ? blocks[i - 1].to_s : ""
        prev_has_topic_url = !!(prev =~ TEXT_TOPIC_URL_REGEX)
        next unless prev_has_topic_url

        prev_tid = extract_topic_id_from_text_block(prev)
        if !prev_tid.empty? && protected[prev_tid]
          next
        end

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
      Rails.logger.warn("digest-campaigns append+trim TEXT trim failed: #{e.class}: #{e.message}")
      nil
    end
  end

  module UserNotificationsExtension
    def self.plain_text_from_post(post)
      return "" if post.nil?

      raw = post.respond_to?(:raw) ? post.raw.to_s : ""
      raw = raw.strip
      return raw unless raw.empty?

      cooked = post.respond_to?(:cooked) ? post.cooked.to_s : ""
      return "" if cooked.empty?

      if Nokogiri
        Nokogiri::HTML(cooked).text.to_s
      else
        cooked.gsub(/<[^>]+>/, " ")
      end
    rescue
      ""
    end

    def self.smart_trim_preview(text, max_chars)
      ::DigestCampaigns::DigestAppendData.smart_trim_plain(text.to_s, max_chars)
    rescue
      text.to_s[0, max_chars].to_s
    end

    def digest(user, opts = {})
      campaign_topic_ids = opts[:campaign_topic_ids]
      campaign_key = opts[:campaign_key]
      campaign_since = opts[:campaign_since]
      campaign_id = opts[:campaign_id] # NEW (must be passed from send job)

      if campaign_topic_ids.blank?
        return super(user, opts)
      end

      build_summary_for(user)

      @campaign_key = campaign_key.to_s
      @unsubscribe_key = UnsubscribeKey.create_key_for(@user, UnsubscribeKey::DIGEST_TYPE)

      @since = nil
      @counts = []

      ids = Array(campaign_topic_ids).map(&:to_i).select { |x| x > 0 }.uniq
      topics = Topic.where(id: ids).includes(:category, :user, :first_post).to_a
      by_id = topics.index_by(&:id)
      topics_for_digest = ids.map { |id| by_id[id] }.compact

      first_topic = topics_for_digest.first
      first_post  = first_topic&.first_post

      popular_n = SiteSetting.digest_topics.to_i
      popular_n = 0 if popular_n < 0
      popular_n = 1 if popular_n == 0 && topics_for_digest.present?

      @popular_topics = topics_for_digest[0, popular_n] || []
      @other_new_for_you =
        if topics_for_digest.size > popular_n
          topics_for_digest[popular_n..-1] || []
        else
          []
        end

      @popular_posts = ::DigestCampaigns.fetch_random_popular_posts(3)

      @excerpts = {}
      @popular_topics.each do |t|
        next if t&.first_post.blank?
        next if t.first_post.user_deleted
        @excerpts[t.first_post.id] = email_excerpt(t.first_post.cooked, t.first_post)
      end

      @popular_posts.each do |p|
        next if p.blank?
        next if p.user_deleted
        @excerpts[p.id] = email_excerpt(p.cooked, p)
      end

      if first_topic
        subj = first_topic.title.to_s.strip
        subject = ::DigestCampaigns::UserNotificationsExtension.smart_trim_preview(subj, 200)

        preview = ::DigestCampaigns::UserNotificationsExtension.plain_text_from_post(first_post)
        preview = ::DigestCampaigns::DigestAppendData.normalize_spaces(preview)
        preview = ::DigestCampaigns::UserNotificationsExtension.smart_trim_preview(preview, 200)
        @preheader_text = preview
      else
        base_subject =
          I18n.t(
            "user_notifications.digest.subject_template",
            email_prefix: @email_prefix,
            date: short_date(Time.now)
          )
        prefix = SiteSetting.digest_campaigns_subject_prefix.to_s.strip
        prefix = "[Campaign Digest]" if prefix.blank?
        subject = "#{prefix} - #{base_subject} - #{@campaign_key}".strip

        @preheader_text = "Campaign Digest"
      end

      html = render_to_string(template: "user_notifications/digest", formats: [:html])

      lines = []
      lines << "Activity Summary"
      lines << "Campaign: #{@campaign_key}" if @campaign_key.present?
      lines << ""
      if topics_for_digest.empty?
        lines << "(No topics)"
      else
        lines << "Topics:"
        topics_for_digest.each_with_index do |t, i|
          lines << "#{i + 1}. #{t.title} - #{Discourse.base_url}/t/#{t.slug}/#{t.id}"
        end
      end
      lines << ""
      lines << "Unsubscribe: #{Discourse.base_url}/email/unsubscribe/#{@unsubscribe_key}"
      text_body = lines.join("\n")

      message = build_email(
        user.email,
        subject: subject,
        body: text_body,
        html_override: html,
        add_unsubscribe_link: true,
        unsubscribe_url: "#{Discourse.base_url}/email/unsubscribe/#{@unsubscribe_key}",
        topic_ids: topics_for_digest.map(&:id),
        post_ids: topics_for_digest.map { |t| t.first_post&.id }.compact
      )

      begin
        email_id = ::DigestCampaigns::DigestAppendData.generate_email_id(campaign_id: campaign_id)

        ::DigestCampaigns::DigestAppendData.email_id_dlog(
          "digest-campaigns email_id=#{email_id} campaign_id=#{campaign_id.inspect} campaign_key=#{@campaign_key.inspect} user_id=#{user&.id}"
        )

        ::DigestCampaigns::DigestAppendData.process_html_part!(message, user, email_id)
        ::DigestCampaigns::DigestAppendData.trim_digest_text_part!(message)
        # MUST run last: swap domains after all other link/trim logic is finished.
        ::DigestCampaigns::DigestAppendData.process_domain_swap!(message)
      rescue => e
        Rails.logger.warn("digest-campaigns append+trim wrapper failed: #{e.class}: #{e.message}")
      end

      message
    end
  end
end
