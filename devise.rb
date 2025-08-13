# frozen_string_literal: true
# =============================================================================
# Rails Template — devise.rb
# Goal: generate a Rails 8.0.2 app ready to go with:
#  - Ruby 3.4.5
#  - Propshaft 1.2.1 (no Sprockets) using the “manifest” mode
#  - jsbundling-rails + cssbundling-rails with NPM
#  - Bootstrap + Popper via NPM (no bootstrap gem)
#  - Devise installed and configured (ensured & idempotent)
#  - Heroku-friendly (Node + Ruby precompilation)
#
# IMPORTANT — How to use this template:
#   rails new \
#     -d postgresql \
#     -m PATH/TO/devise.rb \
#     YOUR_APP_NAME
#
# (The template sets up jsbundling/cssbundling, configures NPM, Propshaft,
#  Bootstrap, and Devise.)
# =============================================================================

# -----------------------------------------------------------------------------#
# Target versions (you can adjust here if needed).
# -----------------------------------------------------------------------------#
RUBY_TARGET       = "3.4.5"   # Ruby version to pin in Gemfile and .ruby-version.
RAILS_TARGET      = "8.0.2"   # Rails version to lock in Gemfile.
PROPSHAFT_VERSION = "1.2.1"   # Propshaft version (pin to avoid surprises).

# -----------------------------------------------------------------------------#
# 1) Kill Spring (optional but avoids cache issues during setup)
#    Why: Spring keeps Ruby processes in memory. Killing it prevents using stale
#    processes while we generate the app.
# -----------------------------------------------------------------------------#
run "pgrep -f spring | xargs -r kill -9 || true"

# -----------------------------------------------------------------------------#
# 2) .ruby-version — enforce same version locally (rbenv/asdf/rvm will read it)
# -----------------------------------------------------------------------------#
file ".ruby-version", RUBY_TARGET

# -----------------------------------------------------------------------------#
# 3) Gemfile — impose versions and prepare the app on the Ruby side.
#    - rails '8.0.2' per requirement
#    - propshaft '1.2.1' and ensure no sprockets
#    - devise for authentication
#    - jsbundling-rails / cssbundling-rails to compile via NPM
#    - remove importmap-rails (useless when using jsbundling)
#    NOTE: We now **replace** any existing `gem "propshaft"` line instead of
#    adding a new one, to avoid Bundler errors for duplicates.
# -----------------------------------------------------------------------------#
# Ensure a `ruby "x.y.z"` directive exists; replace/insert as needed.
if File.read("Gemfile") =~ /^ruby /
  gsub_file "Gemfile", /^ruby .*\n/, %(ruby "#{RUBY_TARGET}"\n)
else
  inject_into_file "Gemfile", %(ruby "#{RUBY_TARGET}"\n), after: "source \"https://rubygems.org\"\n"
end

# Lock the Rails version.
gsub_file "Gemfile", /^gem ["']rails["'].*$/, %(gem "rails", "#{RAILS_TARGET}")

# Remove Sprockets & importmap if present (we want to avoid conflicts).
gsub_file "Gemfile", /^gem ["']sprockets-rails["'].*\n/, ""
gsub_file "Gemfile", /^gem ["']importmap-rails["'].*\n/, ""

# Ensure Propshaft is present exactly once and pinned to PROPSHAFT_VERSION.
if File.read("Gemfile") =~ /^gem ["']propshaft["']/
  gsub_file "Gemfile", /^gem ["']propshaft["'].*$/, %(gem "propshaft", "#{PROPSHAFT_VERSION}")
else
  append_to_file "Gemfile", %(
  gem "propshaft", "#{PROPSHAFT_VERSION}"
)
end

# Add our key gems (respecting Rails 8 default Gemfile structure).  
# (We deliberately DO NOT add propshaft here anymore to avoid duplicates.)
append_to_file "Gemfile", <<~RUBY

  # --- Authentication ---
  gem "devise"                            # Battle-tested authentication gem (generates User, controllers, views, etc.)

  # --- Bundling via Node/NPM ---
  gem "jsbundling-rails"                  # Hooks JS bundlers (esbuild/rollup/webpack) into Rails precompile
  gem "cssbundling-rails"                 # Same for CSS (Sass/PostCSS/Bootstrap/Bulma/Tailwind via Node)
RUBY

# Notes:
# - pg, puma, bootsnap… are already present in the default Rails 8 Gemfile.
# - Do NOT add the 'bootstrap' gem. We’ll install Bootstrap from NPM.
# - Do NOT add 'sass-rails' / 'sassc-rails' (Sprockets-era) to avoid conflicts.

# -----------------------------------------------------------------------------#
# 4) Bundle install — install gems above.
# -----------------------------------------------------------------------------#
run "bundle install"

# -----------------------------------------------------------------------------#
# 5) Node / NPM — enforce NPM (not yarn) and install JS/CSS tooling.
#    Explanation:
#      - jsbundling-rails installs a bundler (we choose esbuild for simplicity).
#      - cssbundling-rails installs a preset (we choose bootstrap).
#      - install bootstrap + @popperjs/core via NPM (no bootstrap gem).
# -----------------------------------------------------------------------------#
# Avoid Yarn being chosen by default if it exists on the machine.
run "rm -f yarn.lock"

# Initialize package.json if absent (Rails might not have created it).
run "npm init -y" unless File.exist?("package.json")

# Install and configure the JS bundler (esbuild).
run "bin/rails javascript:install:esbuild"

# Install and configure the CSS bundler with Bootstrap (via Sass CLI).
run "bin/rails css:install:bootstrap"

# Add Bootstrap & Popper on the JS side for interactive components (dropdowns, modals…)
run "npm install bootstrap @popperjs/core"

# Adjust NPM scripts to match the requirement: `npm run build` and `npm run build:css`
# - build     : bundle JS → app/assets/builds (then digested by Propshaft)
# - build:css : compile Bootstrap SCSS → app/assets/builds/application.css
run %(npm pkg set scripts.build="esbuild app/javascript/*.* --bundle --sourcemap --outdir=app/assets/builds --public-path=/assets")
# The Bootstrap preset already created build:css; we overwrite to ensure the exact format and paths we want:
run %(npm pkg set scripts."build:css"="sass ./app/assets/stylesheets/application.bootstrap.scss:./app/assets/builds/application.css --no-source-map")

# -----------------------------------------------------------------------------#
# 6) JS entrypoint — load Bootstrap JS (for tooltips/modals, etc.)
#    Explanation: import "bootstrap" activates Bootstrap’s JS (which depends on
#    Popper for some components).
# -----------------------------------------------------------------------------#
application_js_path = "app/javascript/application.js"
append_to_file application_js_path, %(
// Enable Bootstrap JS components
import "bootstrap"
)

# -----------------------------------------------------------------------------#
# 7) Propshaft — “manifest-only” behavior in production.
#    Key idea: in development, Propshaft serves assets via the load path.
#              in production, after `assets:precompile`, it relies on the MANIFEST
#              (public/assets/.manifest.json) — that’s what you want.
#    Actions:
#     - Add app/assets/builds to the asset paths (where js/css bundles are emitted)
#     - Exclude source folders to avoid duplicates in production
#       (we don’t want source SCSS/JS to be copied as-is).
# -----------------------------------------------------------------------------#
initializer "assets.rb", <<~RUBY
  # Be sure to restart your server when you modify this file.

  # Asset version (handy to invalidate caches if needed)
  Rails.application.config.assets.version = "1.0"

  # Where JS/CSS compiled by bundlers are emitted (then digested by Propshaft)
  Rails.application.config.assets.paths << Rails.root.join("app/assets/builds")

  # Exclude compilation sources from the load path to avoid duplicates in production
  # Explanation: our SCSS (source) becomes a single final CSS file in builds/.
  # Same for JS. We ask Propshaft to ignore the source folders.
  Rails.application.config.assets.excluded_paths << Rails.root.join("app/javascript")
  Rails.application.config.assets.excluded_paths << Rails.root.join("app/assets/stylesheets")
RUBY

# Production: explicitly never compile on the fly.
gsub_file "config/environments/production.rb",
          /#?\s*config\.assets\.compile\s*=.*\n?/,
          "config.assets.compile = false\n"
append_to_file "config/environments/production.rb", <<~RUBY

  # Propshaft in manifest mode (default behavior after precompile):
  # - Files are served via the .manifest.json mapping
  # - Ensures fingerprinted URLs and long cache
  # Heroku: the Ruby build will run `assets:precompile`, which triggers `npm run build`
  # and `npm run build:css` thanks to the *bundling-rails gems.
RUBY

# -----------------------------------------------------------------------------#
# 8) Layout — ensure helpers reference Propshaft bundles.
#    - stylesheet_link_tag "application"         → uses app/assets/builds/application.css
#    - javascript_include_tag "application"      → uses app/assets/builds/application.js
#    - data-turbo-track="reload"                 → auto-reload when assets change
# -----------------------------------------------------------------------------#
gsub_file "app/views/layouts/application.html.erb",
          /<%= stylesheet_link_tag .* %>/,
          %(<%= stylesheet_link_tag "application", "data-turbo-track": "reload" %>)

gsub_file "app/views/layouts/application.html.erb",
          /<%= javascript_include_tag .* %>/,
          %(<%= javascript_include_tag "application", "data-turbo-track": "reload", defer: true %>)

# If the default layout is missing these tags (rare), insert them cleanly.
layout_path = "app/views/layouts/application.html.erb"
if File.exist?(layout_path) && !File.read(layout_path).include?("stylesheet_link_tag")
  inject_into_file layout_path,
    %(
    <%= stylesheet_link_tag "application", "data-turbo-track": "reload" %>
),
    after: /<head>.*\n/
end
if File.exist?(layout_path) && !File.read(layout_path).include?("javascript_include_tag")
  inject_into_file layout_path,
    %(
    <%= javascript_include_tag "application", "data-turbo-track": "reload", defer: true %>
),
    before: %r{</head>}
end

# -----------------------------------------------------------------------------#
# 9) Devise — ensure full installation but avoid duplicates
#    Rationale: Devise must be present after template run, but the generator
#    should be idempotent if the template is rerun or the model/migration exist.
#    Steps:
#      - Run `devise:install` if the initializer is missing.
#      - Generate `devise User` only if both the model and a migration are absent.
#      - If a Devise migration exists, harden it with `if_not_exists` to avoid
#        crashes when the `users` table/index already exist.
# -----------------------------------------------------------------------------#
# 9.1 Install Devise (once)
unless File.exist?("config/initializers/devise.rb")
  generate "devise:install"
end

# 9.2 Generate User model with Devise (if needed)
devise_migration = Dir.glob("db/migrate/*_devise_create_users.rb").first
unless File.exist?("app/models/user.rb") || devise_migration
  generate "devise", "User"
  devise_migration = Dir.glob("db/migrate/*_devise_create_users.rb").first
end

# 9.3 Make Devise migration tolerant to existing DB objects
if devise_migration
  gsub_file devise_migration, /create_table :users do/, 'create_table :users, if_not_exists: true do'
  gsub_file devise_migration, /add_index :users, :email, unique: true\b/, 'add_index :users, :email, unique: true, if_not_exists: true'
  gsub_file devise_migration, /add_index :users, :reset_password_token, unique: true\b/, 'add_index :users, :reset_password_token, unique: true, if_not_exists: true'
end

# 9.4 Mailer hosts for URL generation
environment 'config.action_mailer.default_url_options = { host: "localhost", port: 3000 }', env: "development"
environment 'config.action_mailer.default_url_options = { host: "www.example.com" }', env: "test"

environment <<~RUBY, env: "production"
  config.action_mailer.default_url_options = {
    host: ENV.fetch("APP_HOST") { "example.com" },
    protocol: "https"
  }
RUBY

# -----------------------------------------------------------------------------#
# 10) Flashes — a simple partial + include in the layout.
#      (Bootstrap handles styles .alert .alert-info/success/warning/danger)
# -----------------------------------------------------------------------------#
file "app/views/shared/_flashes.html.erb", <<~ERB
  <% if notice %>
    <div class="alert alert-info alert-dismissible fade show" role="alert">
      <%= notice %>
      <button type="button" class="btn-close" data-bs-dismiss="alert" aria-label="Close"></button>
    </div>
  <% end %>
  <% if alert %>
    <div class="alert alert-warning alert-dismissible fade show" role="alert">
      <%= alert %>
      <button type="button" class="btn-close" data-bs-dismiss="alert" aria-label="Close"></button>
    </div>
  <% end %>
ERB

# Insert the flashes render right after opening <body>.
if File.exist?(layout_path) && !File.read(layout_path).include?('render "shared/flashes"')
  gsub_file layout_path,
            /<body[^>]*>/,
            "\\0\n    <%= render \"shared/flashes\" %>"
end

# -----------------------------------------------------------------------------#
# 11) Minimal home page — quick sanity check that everything works.
# -----------------------------------------------------------------------------#
generate :controller, "pages", "home"
route 'root to: "pages#home"'
append_to_file "app/views/pages/home.html.erb", <<~ERB

  <div class="container py-5">
    <h1 class="mb-3">Hello Rails 8 + Propshaft + Bootstrap + Devise 👋</h1>
    <p>Si tu vois cette page avec du style Bootstrap, c’est gagné.</p>
  </div>
ERB

# -----------------------------------------------------------------------------#
# 12) Procfile (Heroku) — Puma in production.
#     Why: Heroku detects Rails, but declaring Puma explicitly is healthy.
# -----------------------------------------------------------------------------#
file "Procfile", <<~YAML
  web: bundle exec puma -C config/puma.rb
YAML

# -----------------------------------------------------------------------------#
# 13) Gitignore — ignore builds and node_modules; keep a .keep file.
# -----------------------------------------------------------------------------#
append_to_file ".gitignore", <<~TXT

  # --- Node & builds (generated by js/css bundling) ---
  /node_modules
  /app/assets/builds/*
  !/app/assets/builds/.keep
TXT
run "mkdir -p app/assets/builds && touch app/assets/builds/.keep"

# -----------------------------------------------------------------------------#
# 14) Database — create and run Devise (User) migration.
# -----------------------------------------------------------------------------#
rails_command "db:create"
rails_command "db:migrate"

# -----------------------------------------------------------------------------#
# 15) Final prep — build assets once (dev).
#     You can run again locally:
#       npm run build
#       npm run build:css
# -----------------------------------------------------------------------------#
run "npm run build"
run "npm run build:css"

# -----------------------------------------------------------------------------#
# 16) Initial commit (optional) — handy to start from a clean slate.
# -----------------------------------------------------------------------------#
after_bundle do
  git :init
  git add: "."
  git commit: %q(-m "Initial commit: Rails 8.0.2 + Propshaft 1.2.1 + js/css bundling (NPM) + Bootstrap + Devise (ensured & idempotent)")
end

# =============================================================================
# Educational notes (reminder):
# - Propshaft serves assets: in dev from the load paths, in prod via
#   a manifest (.manifest.json) generated by `rails assets:precompile`.
# - jsbundling-rails/cssbundling-rails automatically hook `npm run build`
#   and `npm run build:css` into `assets:precompile`. On Heroku, the Ruby
#   build will execute these scripts if the Node buildpack comes before the
#   Ruby buildpack.
# - We do NOT use the bootstrap gem (avoid Sprockets conflicts). Everything goes
#   through NPM → propshaft → helpers (`stylesheet_link_tag`/`javascript_include_tag`).
# =============================================================================
