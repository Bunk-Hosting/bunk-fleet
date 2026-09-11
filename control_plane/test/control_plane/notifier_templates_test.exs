defmodule ControlPlane.Notifier.TemplatesTest do
  use ExUnit.Case, async: true

  alias ControlPlane.Notifier.Templates

  @url "https://app.bunkhosting.nl/verify-email?token=abc123"

  describe "confirmation/2" do
    test "renders the branded HTML layout around the confirmation body" do
      {_text, html} = Templates.confirmation("Stijn", @url)

      assert html =~ "<!DOCTYPE html>"
      assert html =~ "BUNK HOSTING"
      assert html =~ "Bevestig je e-mailadres"
      assert html =~ "24 uur geldig"
      # The CTA and the fallback "copy this link" both carry the URL.
      assert html =~ @url
      assert html =~ "Hoi Stijn,"
    end

    test "renders the plain-text alternative with the same core facts" do
      {text, _html} = Templates.confirmation("Stijn", @url)

      assert text =~ "Hoi Stijn,"
      assert text =~ @url
      assert text =~ "24 uur geldig"
    end

    test "an account without a name greets without a dangling space, in both formats" do
      {text, html} = Templates.confirmation(nil, @url)
      assert html =~ "Hoi,"
      refute html =~ "Hoi ,"
      assert text =~ "Hoi,"
      refute text =~ "Hoi ,"

      {text, html} = Templates.confirmation("   ", @url)
      assert html =~ "Hoi,"
      assert text =~ "Hoi,"
    end
  end

  describe "reset_password/2" do
    test "renders the reset body with its own expiry copy in both formats" do
      {text, html} = Templates.reset_password("Stijn", @url)

      assert html =~ "Wachtwoord resetten"
      assert html =~ "1 uur geldig"
      assert html =~ @url

      assert text =~ "wachtwoord"
      assert text =~ "1 uur geldig"
      assert text =~ @url
    end
  end

  describe "low_balance/4" do
    test "names the VPS and the retry date in both formats" do
      {text, html} =
        Templates.low_balance("Stijn", "web-01", "11-09-2026", "https://app.bunkhosting.nl/dashboard/billing")

      assert html =~ "Je saldo is te laag"
      assert html =~ "web-01"
      assert html =~ "11-09-2026"
      assert html =~ "er is niets verwijderd"

      assert text =~ "web-01"
      assert text =~ "11-09-2026"
      assert text =~ "er wordt niets verwijderd"
    end
  end

  describe "escaping" do
    test "a name containing markup cannot inject into the HTML body" do
      {_text, html} = Templates.confirmation(~S|<script>alert("x")</script>|, @url)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "a name containing a quote cannot break out of an HTML attribute" do
      {_text, html} = Templates.confirmation(~S|Stijn" onmouseover="evil|, @url)

      refute html =~ ~S|onmouseover="evil|
      assert html =~ "&quot;"
    end

    test "a VPS name is escaped too, in the HTML body" do
      {_text, html} = Templates.low_balance("Stijn", "<b>web</b>", "11-09-2026", @url)

      refute html =~ "<b>web</b>"
      assert html =~ "&lt;b&gt;web&lt;/b&gt;"
    end

    test "the same attack payloads are NOT escaped in the plain-text body" do
      # The text alternative has no markup to break out of, so escaping it
      # would only leave literal &lt;/&quot; garbage in a mail client that
      # renders text verbatim. The raw customer input must survive intact.
      {text, _html} = Templates.confirmation(~S|<script>alert("x")</script>|, @url)

      assert text =~ ~S|<script>alert("x")</script>|
      refute text =~ "&lt;script&gt;"

      {text, _html} = Templates.confirmation(~S|Stijn" onmouseover="evil|, @url)
      assert text =~ ~S|Stijn" onmouseover="evil|
      refute text =~ "&quot;"

      {text, _html} = Templates.low_balance("Stijn", "<b>web</b>", "11-09-2026", @url)
      assert text =~ "<b>web</b>"
      refute text =~ "&lt;b&gt;web&lt;/b&gt;"
    end

    test "the plain-text body never contains HTML entities or tags for ordinary input" do
      for {text, _html} <- [
            Templates.confirmation("Stijn", @url),
            Templates.reset_password("Stijn", @url),
            Templates.low_balance("Stijn", "web-01", "11-09-2026", @url)
          ] do
        refute text =~ ~r/<[a-zA-Z!\/][^>]*>/, "text body unexpectedly contains an HTML tag: #{inspect(text)}"
        refute text =~ ~r/&[a-zA-Z]+;|&#\d+;/, "text body unexpectedly contains an HTML entity: #{inspect(text)}"
      end
    end
  end
end
