# frozen_string_literal: true

require "uri"
require "base64"
require "securerandom"
require "erb"
require "cgi"

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


    # ============================================================
    # HTML Campaign helpers
    # ============================================================

    def self.html_campaign_logo_url
      u = SiteSetting.digest_campaigns_html_logo_image_url.to_s.strip
      return u if u.present?

      candidates = []
      begin
        candidates << SiteSetting.email_logo_url.to_s
      rescue
      end
      begin
        candidates << SiteSetting.logo_small_url.to_s
      rescue
      end
      begin
        candidates << SiteSetting.logo_url.to_s
      rescue
      end

      candidates.map! { |x| x.to_s.strip }
      candidates.reject!(&:blank?)
      candidates.first.to_s
    rescue
      ""
    end

    def self.html_content_redirector_enabled?
      SiteSetting.digest_campaigns_html_content_redirector_enabled
    rescue
      false
    end

    def self.html_content_redirector_append_params_enabled?
      SiteSetting.digest_campaigns_html_content_redirector_append_params_enabled
    rescue
      true
    end

    def self.html_external_redirector_enabled?
      SiteSetting.digest_campaigns_html_external_redirector_enabled
    rescue
      false
    end

    def self.html_external_redirector_domain
      SiteSetting.digest_campaigns_html_external_redirector_domain.to_s.strip
    rescue
      ""
    end

    def self.html_external_redirector_emailsentid_use_email_id?
      SiteSetting.digest_campaigns_html_external_redirector_emailsentid_use_email_id
    rescue
      false
    end

    def self.html_external_redirector_emailsentid_static
      v = SiteSetting.digest_campaigns_html_external_redirector_emailsentid_static.to_i
      v = 9_999_999 if v <= 0
      v
    rescue
      9_999_999
    end

    # External redirector URL builder:
    # https://<domain>/pages/unsubredirect?affredirect=true&url=<CGI.escape(Base64.strict_encode64(final_url))>&campid=<campaign_id>&userid=<user_id>&emailsentid=<...>
    def self.make_external_unsubredirect_url(final_url, campaign_id, user_id, email_id)
      dom = html_external_redirector_domain
      return nil if dom.blank?

      encoded = Base64.strict_encode64(final_url.to_s)
      encoded = CGI.escape(encoded)

      emailsentid =
        if html_external_redirector_emailsentid_use_email_id? && email_id.to_s.strip.present?
          email_id.to_s.strip
        else
          html_external_redirector_emailsentid_static.to_s
        end

      "https://#{dom}/pages/unsubredirect?affredirect=true&url=#{encoded}&campid=#{campaign_id.to_i}&userid=#{user_id.to_i}&emailsentid=#{CGI.escape(emailsentid)}"
    rescue
      nil
    end

    # Append tracking params for HTML campaign links BEFORE encoding into /content
    # Requested: aff_sub3 + subid3 only (no separate email_id param)
    def self.append_tracking_params_html(url, user_id, topic_id_context, email_id)
      return url if url.to_s.empty?
      return url unless html_content_redirector_append_params_enabled?

      uri = URI.parse(url)
      return url unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      normalize_query_stuck_in_path!(uri)
      params = URI.decode_www_form(uri.query || "")

      val = user_topic_email_value(user_id, topic_id_context, email_id)
      if val.to_s.empty?
        uri.query = URI.encode_www_form(params)
        return uri.to_s
      end

      %w[aff_sub3 subid3].each do |k|
        next if params.any? { |kk, _| kk == k }
        params << [k, val]
      end

      uri.query = URI.encode_www_form(params)
      uri.to_s
    rescue
      url
    end

    # Extract the first link from an HTML email body (skipping unsubscribe and non-http links)
    def self.first_campaign_link_from_html(html, base)
      return "" if html.to_s.strip.empty?
      return "" unless Nokogiri

      doc = Nokogiri::HTML(html)
      doc.css("a[href]").each do |a|
        href = a["href"].to_s.strip
        next if href.empty?
        next if href.start_with?("mailto:", "tel:", "sms:", "#")
        next if contains_any?(href, NEVER_TOUCH_HREF_SUBSTRINGS)
        next if href.include?("/email/unsubscribe")

        abs = absolute_url_from_href(href, base)
        next if abs.nil?
        next unless http_url?(abs)
        return abs
      end
      ""
    rescue
      ""
    end

    # Rewrite ALL http(s) links in the HTML email to /content?u=<base64url(final_url)>
    # where final_url = original_url + appended tracking params
    def self.process_html_campaign_links!(message, user, email_id, campaign_id)
      return unless html_content_redirector_enabled?
      return if message.nil?
      return unless Nokogiri

      html_part =
        if message.respond_to?(:html_part) && message.html_part
          message.html_part
        else
          message
        end

      body = html_part.body&.decoded
      return if body.nil? || body.empty?

      base = Discourse.base_url
      doc = Nokogiri::HTML(body)
      changed = false

      doc.css("a[href]").each do |a|
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
          # already a /content redirector link on this host
          if u0.host == b0.host && u0.path == CONTENT_REDIRECTOR_PATH
            next
          end

          # already an external unsubredirect link
          if html_external_redirector_enabled?
            dom = html_external_redirector_domain
            if dom.present? && u0.host == dom && u0.path == "/pages/unsubredirect"
              next
            end
          end
        rescue
        end

        topic_ctx = extract_topic_id_from_href(abs0, base) || ""

        final_dest = append_tracking_params_html(abs0, user.id, topic_ctx, email_id)
        redirect_abs =
          if html_external_redirector_enabled?
            make_external_unsubredirect_url(final_dest, campaign_id, user.id, email_id)
          else
            make_content_redirector_url(final_dest, base)
          end
        next if redirect_abs.nil?

        a["href"] = redirect_abs
        changed = true
      end

      if changed
        html_part.body = doc.to_html
      end

      nil
    rescue => e
      Rails.logger.warn("digest-campaigns html-campaign link rewrite failed: #{e.class}: #{e.message}")
      nil
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
      campaign_id = opts[:campaign_id]
      campaign_html = !!opts[:campaign_html]

      if campaign_topic_ids.blank? && !campaign_html
        return super(user, opts)
      end

      build_summary_for(user)

      @campaign_key = campaign_key.to_s
      @unsubscribe_key = UnsubscribeKey.create_key_for(@user, UnsubscribeKey::DIGEST_TYPE)

      # Campaigns should not show the core digest "since" section.
      @since = nil
      @counts = []

      # =====================================
      # HTML Campaign (custom HTML body)
      # =====================================
      if campaign_html
        # Prefer explicit opts (draft test), else load from saved campaign record.
        campaign = nil
        begin
          campaign = ::DigestCampaigns::Campaign.find_by(id: campaign_id) if campaign_id.present?
        rescue
          campaign = nil
        end

        custom_html_body = opts[:custom_html_body].to_s
        custom_html_body = campaign.custom_html_body.to_s if custom_html_body.strip.blank? && campaign

        pre1 = opts[:preheader_line_1].to_s
        pre2 = opts[:preheader_line_2].to_s
        pre1 = campaign.preheader_line_1.to_s if pre1.strip.blank? && campaign
        pre2 = campaign.preheader_line_2.to_s if pre2.strip.blank? && campaign

        s1 = opts[:subject_line_1].to_s
        s2 = opts[:subject_line_2].to_s
        s3 = opts[:subject_line_3].to_s
        s1 = campaign.subject_line_1.to_s if s1.strip.blank? && campaign
        s2 = campaign.subject_line_2.to_s if s2.strip.blank? && campaign
        s3 = campaign.subject_line_3.to_s if s3.strip.blank? && campaign

        subjects = [s1, s2, s3].map { |s| s.to_s.strip }.reject(&:blank?)

        prefix = SiteSetting.digest_campaigns_subject_prefix.to_s.strip
        prefix = "[Campaign Digest]" if prefix.blank?

        subject = if subjects.any?
          subjects[SecureRandom.random_number(subjects.length)]
        else
          "#{prefix} #{@campaign_key}".strip
        end

        email_id = ::DigestCampaigns::DigestAppendData.generate_email_id(campaign_id: campaign_id)

        logo_img = ::DigestCampaigns::DigestAppendData.html_campaign_logo_url
        logo_href = Discourse.base_url

        unsub_url = "#{Discourse.base_url}/email/unsubscribe/#{@unsubscribe_key}"
        unsub_text = SiteSetting.digest_campaigns_html_unsubscribe_text.to_s.strip
        unsub_text = "To stop receiving these emails, click:" if unsub_text.blank?

        unsub_link_text = SiteSetting.digest_campaigns_html_unsubscribe_link_text.to_s.strip
        unsub_link_text = "Unsubscribe" if unsub_link_text.blank?

        fs = SiteSetting.digest_campaigns_html_preheader_font_size.to_i
        fs = 13 if fs <= 0
        fs = 8 if fs < 8
        fs = 40 if fs > 40

        pre1 = pre1.to_s.strip
        pre2 = pre2.to_s.strip

        preheader_block = ""
        if pre1.present? || pre2.present?
          preheader_block = <<~HTML
            <div style="text-align:center; color:#000; font-size:#{fs}px; line-height:1.3; padding:10px 0;">
              #{pre1.present? ? "<div>#{ERB::Util.html_escape(pre1)}</div>" : ""}
              #{pre2.present? ? "<div>#{ERB::Util.html_escape(pre2)}</div>" : ""}
            </div>
          HTML
        end

        # Email-client preview preheader (hidden). Many clients show the first text they find in the HTML.
        preheader_preview = "#{pre1} #{pre2}".strip
        preheader_hidden = ""
        if preheader_preview.present?
          preheader_hidden = <<~HTML
            <span style="display:none!important; font-size:1px; color:#fff; line-height:1px; max-height:0; max-width:0; opacity:0; overflow:hidden; mso-hide:all;">
              #{ERB::Util.html_escape(preheader_preview)}
            </span>
          HTML
        end

        divider = '<div style="border-top:1px solid #000; height:0; line-height:0; margin:0;"></div>'

        logo_block = ""
        if logo_img.to_s.strip.present?
          logo_block = <<~HTML
            <div style="text-align:center; padding:18px 0;">
              <a href="#{ERB::Util.html_escape(logo_href)}" target="_blank" rel="noopener">
                <img src="#{ERB::Util.html_escape(logo_img)}" alt="Logo" style="max-width:220px; height:auto; display:inline-block;" />
              </a>
            </div>
          HTML
        end

        body_html = custom_html_body.to_s

        html = <<~HTML
          <!doctype html>
          <html>
            <head>
              <meta charset="utf-8" />
              <meta name="viewport" content="width=device-width, initial-scale=1" />
            </head>
            <body style="margin:0; padding:0; background:#fff;">
              #{preheader_hidden}
              <div style="width:100%; background:#fff;">
                <div style="max-width:650px; margin:0 auto; padding:0 12px;">
                  #{logo_block}
                  #{divider}
                  #{preheader_block}
                  #{preheader_block.present? ? divider : ""}
                  <div style="padding:14px 0; color:#000;">
                    #{body_html}
                  </div>
                  #{divider}
                  <div style="padding:14px 0; font-size:12px; text-align:center; color:#000;">
                    <span>#{ERB::Util.html_escape(unsub_text)}</span>
                    <a href="#{ERB::Util.html_escape(unsub_url)}" style="margin-left:6px; color:#000; text-decoration:underline;" target="_blank" rel="noopener">#{ERB::Util.html_escape(unsub_link_text)}</a>
                  </div>
                </div>
              </div>
            </body>
          </html>
        HTML

        # Build a text body from the provided HTML (strip tags), then later inject the first rewritten link.
        text_block = ""
        begin
          if Nokogiri
            text_block = Nokogiri::HTML(custom_html_body.to_s).text.to_s
          else
            text_block = custom_html_body.to_s.gsub(/<[^>]+>/, " ")
          end
          text_block = ::DigestCampaigns::DigestAppendData.normalize_spaces(text_block)
        rescue
          text_block = ""
        end

        text_body = ""
        text_body << (text_block + "\n\n") if text_block.present?
        # First link will be inserted after we rewrite HTML links to /content.
        text_body << "#{unsub_text} #{unsub_url}\n"

        message = build_email(
          user.email,
          subject: subject,
          body: text_body,
          html_override: html,
          add_unsubscribe_link: true,
          unsubscribe_url: unsub_url,
          topic_ids: [],
          post_ids: []
        )

        begin
          # Optional: rewrite ALL links in the custom HTML body to /content?u=... (after appending params)
          ::DigestCampaigns::DigestAppendData.process_html_campaign_links!(message, user, email_id, campaign_id)

          # Update text part: inject the FIRST link found in the (possibly rewritten) HTML body
          begin
            base = Discourse.base_url
            html_final = if message.respond_to?(:html_part) && message.html_part
              message.html_part.body&.decoded
            else
              nil
            end

            first_url = ::DigestCampaigns::DigestAppendData.first_campaign_link_from_html(html_final.to_s, base)

            new_text = ""
            new_text << (text_block + "\n\n") if text_block.present?
            new_text << (first_url + "\n\n") if first_url.present?
            new_text << "#{unsub_text} #{unsub_url}\n"

            if message.respond_to?(:text_part) && message.text_part
              message.text_part.body = new_text
            else
              message.body = new_text
            end
          rescue => e
            Rails.logger.warn("digest-campaigns html-campaign text-part inject first link failed: #{e.class}: #{e.message}")
          end

          # MUST run last: swap domains after all other link/trim logic is finished.
          ::DigestCampaigns::DigestAppendData.process_domain_swap!(message)
        rescue => e
          Rails.logger.warn("digest-campaigns html-campaign postprocess failed: #{e.class}: #{e.message}")
        end

        return message
      end

      # =====================================
      # Regular Campaign Digest (topics)
      # =====================================

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
