defmodule ControlPlane.Notifier.TemplatesTest do
  use ExUnit.Case, async: true

  alias ControlPlane.Notifier.Templates

  @url "https://app.bunkhosting.nl/verify-email?token=abc123"

  describe "confirmation/2" do
    test "renders the branded layout around the confirmation body" do
      html = Templates.confirmation("Stijn", @url)

      assert html =~ "<!DOCTYPE html>"
      assert html =~ "BUNK HOSTING"
      assert html =~ "Bevestig je e-mailadres"
      assert html =~ "24 uur geldig"
      # The CTA and the fallback "copy this link" both carry the URL.
      assert html =~ @url
      assert html =~ "Hoi Stijn,"
    end

    test "an account without a name greets without a dangling space" do
      html = Templates.confirmation(nil, @url)
      assert html =~ "Hoi,"
      refute html =~ "Hoi ,"

      html = Templates.confirmation("   ", @url)
      assert html =~ "Hoi,"
    end
  end

  describe "reset_password/2" do
    test "renders the reset body with its own expiry copy" do
      html = Templates.reset_password("Stijn", @url)

      assert html =~ "Wachtwoord resetten"
      assert html =~ "1 uur geldig"
      assert html =~ @url
    end
  end

  describe "low_balance/4" do
    test "names the VPS and the retry date" do
      html = Templates.low_balance("Stijn", "web-01", "11-09-2026", "https://app.bunkhosting.nl/dashboard/billing")

      assert html =~ "Je saldo is te laag"
      assert html =~ "web-01"
      assert html =~ "11-09-2026"
      assert html =~ "er is niets verwijderd"
    end
  end

  describe "escaping" do
    test "a name containing markup cannot inject into the body" do
      html = Templates.confirmation(~S|<script>alert("x")</script>|, @url)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "a name containing a quote cannot break out of an attribute" do
      html = Templates.confirmation(~S|Stijn" onmouseover="evil|, @url)

      refute html =~ ~S|onmouseover="evil|
      assert html =~ "&quot;"
    end

    test "a VPS name is escaped too" do
      html = Templates.low_balance("Stijn", "<b>web</b>", "11-09-2026", @url)

      refute html =~ "<b>web</b>"
      assert html =~ "&lt;b&gt;web&lt;/b&gt;"
    end
  end
end
