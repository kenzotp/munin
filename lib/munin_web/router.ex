defmodule MuninWeb.Router do
  use MuninWeb, :router

  import MuninWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MuninWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug MuninWeb.Plugs.ApiTokenAuth
  end

  scope "/", MuninWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Machine doors: token-authed (Hugin agent, phone PWA, paperless-compatible
  # uploaders). Session auth deliberately does NOT apply here.
  scope "/api", MuninWeb do
    pipe_through :api

    get "/health", HealthController, :show
    post "/upload", UploadController, :create
    post "/documents/:id/read", UploadController, :read
  end

  ## Authentication routes

  scope "/", MuninWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{MuninWeb.UserAuth, :require_authenticated}] do
      live "/documents", DocumentsLive
      live "/documents/:id", DocumentLive
      live "/reminders", RemindersLive
      live "/money", MoneyLive
      live "/money/tx", TransactionsLive
      live "/money/import", ImportLive
      live "/tax", TaxLive
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", MuninWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{MuninWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
