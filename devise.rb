# frozen_string_literal: true
# =============================================================================
# Rails Template — devise.rb
# Goal: generate a Rails 8.0.2 app ready to go with:
#  - Ruby 3.4.5
#  - Propshaft 1.2.1 (no Sprockets) using the “manifest” mode
#  - jsbundling-rails + cssbundling-rails with **NPM (no Yarn)**
#  - Bootstrap + Popper via NPM (no bootstrap gem)
#  - Devise installed and configured
#  - Heroku-friendly (Node + Ruby precompilation)
#  - Node >= 18 enforced (avoid esbuild/postcss engine errors)
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
# 2) Versions files — Ruby & Node (nvm)
#    .ruby-version pins Ruby per project; .nvmrc guides nvm to Node 20 (>=18)
# -----------------------------------------------------------------------------#
file ".ruby-version", RUBY_TARGET
file ".nvmrc", "20\n"

# -----------------------------------------------------------------------------#
# 3) Gemfile — pin Rails, ensure Propshaft (once), add Devise + bundlers, drop
#    importmap/sprockets to avoid conflicts with our NPM/Propshaft setup.
#    Also, define a **no-op importmap:install** task so any external attempts
#    to run it succeed harmlessly (Rails new sometimes triggers it by default).
#    Finally, create a local **bin/yarn shim → npm** so any generator that
#    insists on calling `yarn` will actually use npm under the hood.
# -----------------------------------------------------------------------------#
if File.read("Gemfile") =~ /^ruby /
  gsub_file "Gemfile", /^ruby .*\n/, %(ruby "#{RUBY_TARGET}"\n)
else
  inject_into_file "Gemfile", %(ruby "#{RUBY_TARGET}"\n), after: "source \"https://rubygems.org\"\n"
end

gsub_file "Gemfile", /^gem ["']rails["'].*$/, %(gem "rails", "#{RAILS_TARGET}")

gsub_file "Gemfile", /^gem ["']sprockets-rails["'].*\n/, ""

gsub_file "Gemfile", /^gem ["']importmap-rails["'].*\n/, ""

if File.read("Gemfile") =~ /^gem ["']propshaft["']/
  gsub_file "Gemfile", /^gem ["']propshaft["'].*$/, %(gem "propshaft", "#{PROPSHAFT_VERSION}")
else
  append_to_file "Gemfile", %(
  gem "propshaft", "#{PROPSHAFT_VERSION}"
)
end

append_to_file "Gemfile", <<~RUBY

  # --- Authentication ---
  gem "devise"

  # --- Bundling via Node/NPM ---
  gem "jsbundling-rails"
  gem "cssbundling-rails"
RUBY

# Define a NO-OP importmap:install task to avoid noisy errors if invoked.
file "lib/tasks/importmap_noop.rake", <<~RAKE
  namespace :importmap do
    desc "No-op: we use jsbundling-rails + npm (no importmap)."
    task :install do
      puts "[importmap] Skipped (using jsbundling-rails + npm)."
    end
  end
RAKE

# Create a local yarn shim that proxies to npm (used by some installers)
file "bin/yarn", <<~BASH
  #!/usr/bin/env bash
  exec npm "$@"
BASH
run "chmod +x bin/yarn"

# -----------------------------------------------------------------------------#
# 4) Bundle install — install gems above.
# -----------------------------------------------------------------------------#
run "bundle install"

# -----------------------------------------------------------------------------#
# 5) Node / NPM — NPM-only setup
#    Steps:
#     - Remove Yarn artifacts (prevents Yarn auto-detection)
#     - Ensure package.json exists
#     - Set engines.node ">=18" and packageManager to npm
#     - Install esbuild + sass (dev) and bootstrap + popper (runtime)
#     - Run the Rails installers (they may try `yarn add`, but our bin/yarn shim
#       will transparently call npm). This keeps the usual file structure.
#     - Normalize bin/dev to use npm rather than yarn
#     - Define build scripts (JS & CSS)
# -----------------------------------------------------------------------------#
run "rm -f yarn.lock .yarnrc .yarnrc.yml"
run "rm -rf .yarn .pnp.cjs .pnp.loader.mjs"

run "npm init -y" unless File.exist?("package.json")

run %(npm pkg set engines.node=">=18")
run %(npm pkg set packageManager="npm@latest")

# Core tooling and runtime deps
run "npm install --save-dev esbuild sass"
run "npm install bootstrap @popperjs/core"

# Call Rails installers (safe: yarn → npm via our shim)
run "bin/rails javascript:install:esbuild"
run "bin/rails css:install:bootstrap"

# Normalize bin/dev scripts to npm
if File.exist?("bin/dev")
  gsub_file "bin/dev", /yarn build:css --watch/, "npm run build:css -- --watch"
  gsub_file "bin/dev", /yarn build --watch/, "npm run build -- --watch"
  gsub_file "bin/dev", /yarn build:css/, "npm run build:css"
  gsub_file "bin/dev", /yarn build/, "npm run build"
end

# Ensure expected build scripts (overrides installer defaults as needed)
run %(npm pkg set scripts.build="esbuild app/javascript/*.* --bundle --sourcemap --outdir=app/assets/builds --public-path=/assets")
run %(npm pkg set scripts."build:css"="sass ./app/assets/stylesheets/application.bootstrap.scss:./app/assets/builds/application.css --no-source-map --load-path=node_modules")

# -----------------------------------------------------------------------------#
# 6) JS entrypoint — ensure application.js exists, then import Bootstrap JS
#    (installers create the file; this is a safe append and idempotent)
# -----------------------------------------------------------------------------#
application_js_path = "app/javascript/application.js"
run "mkdir -p app/javascript"
unless File.exist?(application_js_path)
  file application_js_path, <<~JS
    // Entry point for the build script in your package.json
  JS
end
append_to_file application_js_path, %(
// Enable Bootstrap JS components
import "bootstrap"
)

# -----------------------------------------------------------------------------#
# 7) Propshaft — “manifest-only” behavior in production.
#    In development, Propshaft serves assets via the load path.
#    In production, after `assets:precompile`, it relies on the manifest.
#    We add the builds path and exclude source trees to avoid duplicates.
# -----------------------------------------------------------------------------#
initializer "assets.rb", <<~RUBY
  Rails.application.config.assets.version = "1.0"
  Rails.application.config.assets.paths << Rails.root.join("app/assets/builds")
  Rails.application.config.assets.excluded_paths << Rails.root.join("app/javascript")
  Rails.application.config.assets.excluded_paths << Rails.root.join("app/assets/stylesheets")
RUBY

gsub_file "config/environments/production.rb",
          /#?\s*config\.assets\.compile\s*=.*\n?/,
          "config.assets.compile = false\n"
append_to_file "config/environments/production.rb", <<~RUBY
  # Propshaft in manifest mode (default behavior after precompile):
  # - Files are served via the .manifest.json mapping
  # - Ensures fingerprinted URLs and long cache
RUBY

# -----------------------------------------------------------------------------#
# 8) Layout — ensure helpers reference Propshaft bundles.
#    - stylesheet_link_tag "application"  → app/assets/builds/application.css
#    - javascript_include_tag "application" → app/assets/builds/application.js
# -----------------------------------------------------------------------------#
gsub_file "app/views/layouts/application.html.erb",
          /<%= stylesheet_link_tag .* %>/,
          %(<%= stylesheet_link_tag "application", "data-turbo-track": "reload" %>)

gsub_file "app/views/layouts/application.html.erb",
          /<%= javascript_include_tag .* %>/,
          %(<%= javascript_include_tag "application", "data-turbo-track": "reload", defer: true %>)

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
# 9) Devise — install + User model + URL config per environment.
# -----------------------------------------------------------------------------#
generate "devise:install"

generate "devise", "User"

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
  # Ensure npm-only after any external installers complete
  system('rm -f yarn.lock .yarnrc .yarnrc.yml'); system('rm -rf .yarn .pnp.cjs .pnp.loader.mjs')
  system('npm pkg set packageManager="npm@latest"')

  git :init
  git add: "."
  git commit: %q(-m "Initial commit: Rails 8.0.2 + Propshaft 1.2.1 + js/css bundling (NPM-only) + Bootstrap + Devise (Node >= 18)")
end

# =============================================================================
# Notes:
# - We purposely avoid Importmap. A no-op importmap:install task prevents noise.
# - Some Rails installers try `yarn`; the bin/yarn shim maps these to `npm`.
# - Propshaft serves assets via a manifest in production (fingerprinted URLs).
# - jsbundling-rails/cssbundling-rails hook our NPM scripts into precompile.
# =============================================================================
