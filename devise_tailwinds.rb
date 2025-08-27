# frozen_string_literal: true
# =============================================================================
# Rails Template: Devise + Tailwind v4 + Tailwind Plus Elements (Rails 8)
#
# Description:
#   Generates a Rails 8 app with:
#     - Ruby 3.4.5
#     - Rails 8.0.2
#     - Propshaft 1.2.1 (no Sprockets) — manifest mode
#     - jsbundling-rails (esbuild) + css via PostCSS (Tailwind CSS v4)
#     - Devise for authentication
#     - Simple Form (Tailwind wrappers)
#     - Tailwind Plus Elements via NPM
#     - Optional Preline helpers (already in your previous template)
#     - Heroku-ready (assets precompile triggers npm scripts)
#
# Usage:
#   rails new YOUR_APP_NAME -d postgresql -m /path/to/this/devise_tailwinds.rb
# =============================================================================

RUBY_VERSION      = "3.4.5"
RAILS_VERSION     = "8.0.2"
PROPSHAFT_VERSION = "1.2.1"

# 1) Stop Spring to avoid stale processes while generating
run "pgrep -f spring | xargs -r kill -9 || true"

# 2) Pin Ruby for this project
file ".ruby-version", RUBY_VERSION

# 3) Gemfile setup — Rails, Propshaft, Devise, bundling gems
def setup_gemfile
  file "package.json", "{}"
  run "rm -f yarn.lock"

  gsub_file "Gemfile", /^ruby .*/, %(ruby "#{RUBY_VERSION}")
  gsub_file "Gemfile", /^gem "rails", .*/, %(gem "rails", "#{RAILS_VERSION}")

  # Remove Sprockets & Importmap
  gsub_file "Gemfile", /^\s*gem "importmap-rails".*\n/, ""
  gsub_file "Gemfile", /^\s*gem "sprockets-rails".*\n/, ""

  # Ensure Propshaft pinned exactly once
  if File.read("Gemfile").match?(/gem "propshaft"/)
    gsub_file "Gemfile", /gem "propshaft".*/, %(gem "propshaft", "#{PROPSHAFT_VERSION}")
  else
    append_to_file "Gemfile", %(\ngem "propshaft", "#{PROPSHAFT_VERSION}"\n)
  end

  append_to_file "Gemfile", <<~GEMS

    # --- Authentication ---
    gem "devise"
    gem "simple_form"

    # --- JS/CSS Bundling (Node) ---
    gem "jsbundling-rails"
    gem "cssbundling-rails"
  GEMS
end

# 4) Node + CSS/JS bundling (NPM-only) — Tailwind v4 + Elements
def setup_node_bundling
  run "npm init -y" unless File.exist?("package.json")
  run "rm -f yarn.lock .yarnrc .yarnrc.yml"
  run "rm -rf .yarn .pnp.cjs .pnp.loader.mjs"

  # Install runtime deps (Turbo/Stimulus, Preline, Elements)
  run "npm install @hotwired/turbo-rails @hotwired/stimulus preline @tailwindplus/elements"

  # Install dev deps (esbuild + PostCSS pipeline with Tailwind v4)
  run "npm install --save-dev esbuild postcss postcss-cli tailwindcss @tailwindcss/postcss autoprefixer"

  # PostCSS config — Tailwind v4 plugin
  file "postcss.config.js", <<~JS
    module.exports = {
      plugins: {
        "@tailwindcss/postcss": {},
        autoprefixer: {}
      }
    };
  JS

  # esbuild config — JS builds to app/assets/builds
  file "esbuild.config.js", <<~JS
    const path = require('path');
    require('esbuild').build({
      entryPoints: ['application.js'],
      bundle: true,
      outdir: path.join(process.cwd(), 'app/assets/builds'),
      absWorkingDir: path.join(process.cwd(), 'app/javascript'),
      sourcemap: true,
      publicPath: '/assets',
    }).catch(() => process.exit(1));
  JS

  # Tailwind v4 CSS entry (no tailwind.config.js needed)
  file "app/assets/stylesheets/application.tailwind.css", <<~CSS
    @import "tailwindcss";
    /* Optional legacy plugins (v4 supports CSS-first) — uncomment if needed:
    @plugin "@tailwindcss/forms";
    @plugin "@tailwindcss/typography";
    */
  CSS

  # Create JS entry + Stimulus + Preline init + Elements import
  file "app/javascript/application.js", <<~JS
    import "@hotwired/turbo-rails"
    import "./controllers"
    import "preline"
    import "@tailwindplus/elements"

    // Auto-init Preline components on Turbo navigation
    document.addEventListener("turbo:load", () => {
      window.HSStaticMethods?.autoInit && window.HSStaticMethods.autoInit();
    });
  JS

  file "app/javascript/controllers/application.js", <<~JS
    import { Application } from "@hotwired/stimulus"
    const application = Application.start()
    application.debug = false
    window.Stimulus = application
    export { application }
  JS

  file "app/javascript/controllers/index.js", <<~JS
    import "./application"
  JS

  # Optional: dedicated Stimulus controller for Preline helpers
  file "app/javascript/controllers/preline_controller.js", <<~JS
    import { Controller } from "@hotwired/stimulus"
    export default class extends Controller {
      connect() {
        window.HSStaticMethods?.autoInit && window.HSStaticMethods.autoInit();
      }
    }
  JS

  # Scripts — one-liners we will reuse on Heroku too
  run %(npm pkg set scripts.build="node esbuild.config.js")
  run %(npm pkg set scripts."build:css"="postcss ./app/assets/stylesheets/application.tailwind.css --output ./app/assets/builds/application.css")
end

# 5) Propshaft + production config
def setup_rails_config
  initializer "assets.rb", <<~RUBY
    Rails.application.config.assets.version = "1.0"
    Rails.application.config.assets.paths << Rails.root.join("app/assets/builds")
    Rails.application.config.assets.excluded_paths << Rails.root.join("app/javascript")
    Rails.application.config.assets.excluded_paths << Rails.root.join("app/assets/stylesheets")
  RUBY

  gsub_file "config/environments/production.rb",
            /#?\s*config\.assets\.compile\s*=.*/,
            "config.assets.compile = false"

  environment <<~RUBY
    config.generators do |generate|
      generate.assets false
      generate.helper false
      generate.test_framework :test_unit, fixture: false
    end
  RUBY
end

# 6) Devise (ensured + idempotent)
def setup_devise
  generate "devise:install" unless File.exist?("config/initializers/devise.rb")
  generate "devise", "User" unless File.exist?("app/models/user.rb") || Dir.glob("db/migrate/*_devise_create_users.rb").first

  if (mig = Dir.glob("db/migrate/*_devise_create_users.rb").first)
    gsub_file mig, /create_table :users do/, 'create_table :users, if_not_exists: true do'
    gsub_file mig, /add_index :users, :email, unique: true\b/, 'add_index :users, :email, unique: true, if_not_exists: true'
    gsub_file mig, /add_index :users, :reset_password_token, unique: true\b/, 'add_index :users, :reset_password_token, unique: true, if_not_exists: true'
  end

  environment 'config.action_mailer.default_url_options = { host: "localhost", port: 3000 }', env: "development"
  environment 'config.action_mailer.default_url_options = { host: "www.example.com" }', env: "test"
  environment <<~RUBY, env: "production"
    config.action_mailer.default_url_options = {
      host: ENV.fetch("APP_HOST") { "example.com" },
      protocol: "https"
    }
  RUBY
end

# 7) UI — flashes, navbar (remote), home page, elements demo
def setup_ui
  # Navbar from your repo (Tailwind variant)
run "mkdir -p app/views/shared"
run %q(curl -fsSL https://raw.githubusercontent.com/nicopeltier/rails-template/refs/heads/master/_navbar_tailwinds_np.html.erb -o app/views/shared/_navbar.html.erb || true)

  # Tailwind flashes (dismiss via Preline data attributes)
  file "app/views/shared/_flashes.html.erb", <<~ERB
    <% if notice %>
      <div id="flash-notice" class="bg-blue-100 border border-blue-400 text-blue-700 px-4 py-3 rounded relative m-3" role="alert">
        <span class="block sm:inline"><%= notice %></span>
        <span class="absolute top-0 bottom-0 right-0 px-4 py-3">
          <button type="button" aria-label="Close" data-hs-remove-element="#flash-notice" class="text-blue-500">✕</button>
        </span>
      </div>
    <% end %>
    <% if alert %>
      <div id="flash-alert" class="bg-orange-100 border border-orange-400 text-orange-700 px-4 py-3 rounded relative m-3" role="alert">
        <span class="block sm:inline"><%= alert %></span>
        <span class="absolute top-0 bottom-0 right-0 px-4 py-3">
          <button type="button" aria-label="Close" data-hs-remove-element="#flash-alert" class="text-orange-500">✕</button>
        </span>
      </div>
    <% end %>
  ERB

  # Layout: inject flashes + navbar after <body>
  layout_path = "app/views/layouts/application.html.erb"
  if File.exist?(layout_path) && !File.read(layout_path).include?('render "shared/flashes"')
    gsub_file layout_path, /<body[^>]*>/, "\\0\n    <%= render \"shared/flashes\" %>\n    <%= render \"shared/navbar\" %>"
  end

  # Root page
  generate :controller, "pages", "home"
  route 'root to: "pages#home"'

  # Elements demo partial + include on home
  file "app/views/shared/_elements_demo.html.erb", <<~ERB
    <button class="px-3 py-2 rounded bg-gray-900 text-white" onclick="document.querySelector('#demo-dialog').show()">Open dialog</button>
    <el-dialog id="demo-dialog">
      <dialog class="rounded-xl p-6 bg-white shadow">
        <p class="text-gray-800">Hello from Tailwind Plus Elements!</p>
        <button class="mt-4 underline" onclick="document.querySelector('#demo-dialog').hide()">Close</button>
      </dialog>
    </el-dialog>
  ERB

  append_to_file "app/views/pages/home.html.erb", <<~ERB

    <div class="container mx-auto px-4 py-8">
      <h1 class="text-2xl font-semibold mb-4">Rails 8 + Propshaft + Tailwind v4 + Devise</h1>
      <%= render "shared/elements_demo" %>
    </div>
  ERB
end

# 8) Optional admin (Trestle)
def setup_trestle
  append_to_file "Gemfile", %q(\n# Admin framework\ngem "trestle"\n) unless File.read("Gemfile").include?('gem "trestle"')
  run "bundle install"
  generate "trestle:install"
  generate "trestle:resource", "User"
end

# ---- Execute all steps ----
setup_gemfile
run "bundle install"

# Simple Form (Tailwind wrappers)
generate "simple_form:install", "--tailwind" unless File.exist?("config/initializers/simple_form_tailwind.rb")

setup_node_bundling
setup_rails_config
setup_devise
setup_ui
# setup_trestle   # uncomment if you want the admin scaffold

# Lock Linux platform for Heroku cache consistency; .env; .gitignore
run "bundle lock --add-platform x86_64-linux"
run "touch .env"
append_to_file ".gitignore", <<~TXT

  /node_modules
  /app/assets/builds/*
  !/app/assets/builds/.keep
TXT
run "mkdir -p app/assets/builds && touch app/assets/builds/.keep"

# Build assets once (useful locally, Heroku will run precompile)
run "npm run build"
run "npm run build:css"

# DB setup
rails_command "db:create"
rails_command "db:migrate"

# Initial commit
after_bundle do
  git :init
  git add: "."
  git commit: %q(-m "Initial commit: Rails 8.0.2 + Propshaft 1.2.1 + Tailwind v4 (PostCSS) + Devise + Elements")
end
