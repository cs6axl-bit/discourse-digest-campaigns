import Component from "@glimmer/component";
import { action } from "@ember/object";
import { Textarea } from "@ember/component";
import { on } from "@ember/modifier";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";

export default class DigestCampaignsHtmlEditor extends Component {
  @action
  onInput(event) {
    if (typeof this.args?.onChange === "function") {
      this.args.onChange(event?.target?.value || "");
    }
  }

  @action
  setup(element) {
    try {
      const textarea = element?.querySelector("textarea");
      if (!textarea) return;

      const tinymce = window?.tinymce;
      if (!tinymce || typeof tinymce.init !== "function") return;

      if (textarea.dataset?.tinymceInited === "1") return;
      textarea.dataset.tinymceInited = "1";

      if (!textarea.id) {
        textarea.id = `dc_html_${Math.random().toString(16).slice(2)}`;
      }

      tinymce.init({
        selector: `#${textarea.id}`,
        menubar: false,
        branding: false,
        plugins: "link lists code",
        toolbar:
          "undo redo | bold italic underline | bullist numlist | link | removeformat | code",
        height: 320,
        setup: (ed) => {
          ed.on("change keyup setcontent", () => {
            const html = ed.getContent() || "";
            if (typeof this.args?.onChange === "function") {
              this.args.onChange(html);
            }
          });
        },
      });
    } catch (e) {
      // eslint-disable-next-line no-console
      console.warn("digest-campaigns TinyMCE init failed", e);
    }
  }

  <template>
    <div {{didInsert this.setup}}>
      <Textarea
        @value={{@value}}
        class="input-xxlarge"
        rows={{@rows}}
        placeholder={{@placeholder}}
        {{on "input" this.onInput}}
      />
      <div class="help-block" style="margin-top:6px;">
        If you load TinyMCE globally (<code>window.tinymce</code>) this field becomes a WYSIWYG editor. Otherwise it stays a plain HTML textarea.
      </div>
    </div>
  </template>
}
