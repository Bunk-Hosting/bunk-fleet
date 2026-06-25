defmodule ControlPlaneWeb.Layouts do
  @moduledoc """
  Minimal layouts for the operator dashboard.

  This app was generated with `--no-html`, so there is no asset pipeline. The
  root layout therefore loads the Phoenix and Phoenix.LiveView JS from a CDN
  (jsdelivr) and boots the LiveSocket inline, and all styling lives in a tiny
  inline `<style>` block — no esbuild/tailwind/node required.
  """
  use ControlPlaneWeb, :html

  embed_templates "layouts/*"
end
