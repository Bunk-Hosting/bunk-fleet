defmodule ControlPlaneWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ControlPlaneWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ControlPlaneWeb.Endpoint

      use ControlPlaneWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ControlPlaneWeb.ConnCase
    end
  end

  setup tags do
    ControlPlane.DataCase.setup_sandbox(tags)
    # The rate limiter is a single global ETS keyed by client IP; every test
    # request comes from 127.0.0.1, so without a per-test reset counters bleed
    # across tests and later ones spuriously hit 429. The two files that assert
    # accumulated limiter state (auth_controller / rate_limiter) run async: false
    # so this reset never races their request sequences.
    ControlPlane.RateLimiter.reset()
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
