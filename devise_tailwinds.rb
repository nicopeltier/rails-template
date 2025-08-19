# frozen_string_literal: true
# =============================================================================
# Rails Template: Devise for Rails 8
#
# Description:
#   Generates a Rails 8 app with a modern asset pipeline, Devise, and other
#   sensible defaults.
#
# Target Stack:
#   - Ruby 3.4.5
#   - Rails 8.0.2
#   - Propshaft (no Sprockets)
#   - jsbundling-rails + cssbundling-rails (with esbuild and Tailwind CSS)
#   - Devise for authentication
#   - Simple Form with Tailwind wrappers
#   - Heroku-ready with a Procfile
#
# Usage:
#   rails new YOUR_APP_NAME \
#     -d postgresql \
#     -m /path/to/this/devise.rb
# =============================================================================

# --- Template Configuration ---
RUBY_VERSION      = "3.4.5"
RAILS_VERSION     = "8.0.2"
PROPSHAFT_VERSION = "1.2.1"

# 1. Stop Spring to ensure a clean run.
run "pgrep -f spring | xargs -r kill -9 || true"

# 2. Set Ruby version for the project.
file ".ruby-version", RUBY_VERSION, force: true

# 3. Create .railsrc to configure Rails installer options.
# This must be done at the top to ensure it's available for subsequent commands.
# We skip Hotwire and Importmap because we manage Turbo/Stimulus via npm and esbuild.
file ".railsrc", "--skip-spring\n--skip-hotwire\n--skip-importmap\n--javascript=npm\n", force: true

# 4. Configure Gemfile for Rails 8, Propshaft, and Bundling.
def setup_gemfile
  # Drop the database to ensure a clean slate, ignoring errors if it doesn't exist.
  run "rails db:drop || true"
  # Force npm as the JavaScript installer by creating a package.json file.
  # This makes the bundler installers default to npm instead of yarn.
  file "package.json", "{}", force: true
  run "rm -f yarn.lock"

  gsub_file "Gemfile", /^ruby .*/, %(ruby "#{RUBY_VERSION}")
  gsub_file "Gemfile", /^gem "rails", .*/, %(gem "rails", "#{RAILS_VERSION}")

  gsub_file "Gemfile", /^\s*# Use JavaScript with ESM import maps.*\n/, ""
  gsub_file "Gemfile", /^\s*gem "importmap-rails".*\n/, ""
  gsub_file "Gemfile", /^\s*gem "sprockets-rails".*\n/, ""

  if File.read("Gemfile").match?(/gem "propshaft"/)
    gsub_file "Gemfile", /gem "propshaft".*/, %(gem "propshaft", "#{PROPSHAFT_VERSION}")
  else
    append_to_file "Gemfile", %(\ngem "propshaft", "#{PROPSHAFT_VERSION}"\n)
  end

  append_to_file "Gemfile", <<~GEMS

    # --- Authentication & Authorization ---
    gem "devise"
    gem "simple_form"
    gem "trestle" # Admin framework

    # --- Asset Bundling ---
    gem "jsbundling-rails"
    gem "cssbundling-rails"
  GEMS
end

# 4. Set up Node.js for asset bundling.
def setup_node_bundling
  # Initialize npm and install base dependencies
  run "rm -f yarn.lock" # Ensure we don't mix package managers
  run "rm -f .yarnrc*" # Remove any Yarn configuration files
  
  # Explicitly set npm as the package manager
  file ".npmrc", "package-manager=npm", force: true
  
  run "npm init -y" unless File.exist?("package.json")
  # --- Manual Node Asset Setup ---
  # The Rails asset generators are unreliable in a scripted environment.
  # We will perform all setup steps manually for full control.

  # 1. Install all required Node.js dependencies as dev dependencies.
  # 1. Install all required Node.js dependencies in one go.
  # The `--save-dev` flag ensures they are added to package.json.
  # 1. Install all required Node.js dependencies in one go, including Turbo and Stimulus.
  say "\n[DIAGNOSTIC] Preparing to install npm packages...", :yellow
  run "npm install --save-dev esbuild postcss-cli autoprefixer tailwindcss @tailwindcss/forms @tailwindcss/typography @hotwired/turbo-rails @hotwired/stimulus"
  run "npm install preline"

  # 2. Create the PostCSS configuration file.
  file "postcss.config.js", <<~JS, force: true
    module.exports = {
      plugins: {
        tailwindcss: {},
        autoprefixer: {},
      },
    };
  JS

  # 3. Create the esbuild configuration file.
  file "esbuild.config.js", <<~JS, force: true
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

  # 4. Create Tailwind configuration file.
  file "tailwind.config.js", <<~JS, force: true
    module.exports = {
      content: [
        './app/views/**/*.html.erb',
        './app/helpers/**/*.rb',
        './app/assets/stylesheets/**/*.css',
        './app/javascript/**/*.js'
      ],
      theme: {
        extend: {},
      },
      plugins: [
        require('@tailwindcss/forms'),
        require('@tailwindcss/typography'),
      ],
    }
  JS

  # 5. Create the main stylesheet with Tailwind CSS imports.
  file "app/assets/stylesheets/application.tailwind.css", <<~CSS, force: true
    @tailwind base;
    @tailwind components;
    @tailwind utilities;
  CSS

  # 5. Create the JavaScript asset files.
  # We create these manually to ensure the correct content and order,
  # avoiding the issues with Rails generators or file injections.

  # a. Main entrypoint: app/javascript/application.js
  file "app/javascript/application.js", <<~JS, force: true
    // Entry point for the build script in package.json
    import "@hotwired/turbo-rails"
    import "./controllers"
    import "preline"

    document.addEventListener("turbo:load", () => {
      window.HSStaticMethods?.autoInit()
    })

  JS

  # b. Stimulus application: app/javascript/controllers/application.js
  file "app/javascript/controllers/application.js", <<~JS, force: true
    import { Application } from "@hotwired/stimulus"
    const application = Application.start()

    // Configure Stimulus development experience
    application.debug = false
    window.Stimulus   = application

    export { application }
  JS

  # c. Stimulus controller loader: app/javascript/controllers/index.js
  file "app/javascript/controllers/index.js", <<~JS, force: true
    // This file is the entrypoint for all your Stimulus controllers.
    // Import and register your controllers here.

    import { application } from "./application"
    import PrelineController from "./preline_controller"
    application.register("preline", PrelineController)
  JS

  # d. Preline Stimulus controller for handling Turbo navigation
  file "app/javascript/controllers/preline_controller.js", <<~JS, force: true
import { Controller } from "@hotwired/stimulus"
import { HSDropdown, HSCollapse } from "preline"

export default class extends Controller {
  connect() {
    this.initializePreline()
  }

  initializePreline() {
    // Initialize dropdowns
    HSDropdown.autoInit()
    
    // Initialize collapse components (for mobile menu)
    HSCollapse.autoInit()
  }
}
  JS

  # Update the application layout to use the bundled assets instead of importmaps.
  layout_path = "app/views/layouts/application.html.erb"
  gsub_file layout_path, /<%= stylesheet_link_tag .*%>/, '<%= stylesheet_link_tag "application", "data-turbo-track": "reload" %>'

  # Ensure the JavaScript bundle is included correctly.
  insert_into_file layout_path,
                   "    <%= javascript_include_tag \"application\", \"data-turbo-track\": \"reload\", defer: true %>\n",
                   before: /\s*<\/head>/
end

# 5. Configure Propshaft and Rails generators.
def setup_rails_config
  initializer "assets.rb", <<~RUBY, force: true
    Rails.application.config.assets.version = "1.0"
    Rails.application.config.assets.paths << Rails.root.join("app/assets/builds")
    Rails.application.config.assets.excluded_paths << Rails.root.join("app/javascript")
    Rails.application.config.assets.excluded_paths << Rails.root.join("app/assets/stylesheets")
  RUBY

  gsub_file "config/environments/production.rb", /#?\s*config\.assets\.compile\s*=.*/, "config.assets.compile = false"

  environment <<~RUBY
    config.generators do |generate|
      generate.assets false
      generate.helper false
      generate.test_framework :test_unit, fixture: false
    end
  RUBY

  environment 'config.action_controller.raise_on_missing_callback_actions = false if Rails.version >= "7.1.0"'
end

# 6. Install and configure Devise.
def setup_devise
  generate "devise:install" unless File.exist?("config/initializers/devise.rb")
  gsub_file "config/initializers/devise.rb",
            /config\.mailer_sender = .*/,
            'config.mailer_sender = "please-change-me-at-config-initializers-devise@example.com"'

  # Configure Devise to use DELETE for sign-out, which is the secure default.
  uncomment_lines "config/initializers/devise.rb", /config\.sign_out_via = :delete/

  generate "devise", "User" unless File.exist?("app/models/user.rb")

  devise_migration = Dir.glob("db/migrate/*_devise_create_users.rb").first
  if devise_migration
    gsub_file devise_migration, /create_table :users do/, 'create_table :users, if_not_exists: true do'
    gsub_file devise_migration, /(add_index.*)/, 'add_index :users, :email, unique: true, if_not_exists: true'
    gsub_file devise_migration, /(add_index.*)/, 'add_index :users, :reset_password_token, unique: true, if_not_exists: true'
  end

  # Add admin flag to User model and migrate.
  generate "migration", "add_admin_to_users admin:boolean"
  admin_migration = Dir.glob("db/migrate/*_add_admin_to_users.rb").first
  if admin_migration
    gsub_file admin_migration, /add_column :users, :admin, :boolean/, "add_column :users, :admin, :boolean, default: false"
  end

  # Add is_admin? method to User model.
  inject_into_file "app/models/user.rb", after: "class User < ApplicationRecord\n" do
    <<-'RUBY'
  def is_admin?
    admin
  end

    RUBY
  end

  file "app/controllers/application_controller.rb", <<~RUBY, force: true
    class ApplicationController < ActionController::Base
      before_action :authenticate_user!
    end
  RUBY

  generate("devise:views")
  link_to = '<p>Unhappy? <%= link_to "Cancel my account", registration_path(resource_name), data: { confirm: "Are you sure?" }, method: :delete %></p>'
  button_to = '<div class="d-flex align-items-center">'
              '  <div>Unhappy?</div>'
              '  <%= button_to "Cancel my account", registration_path(resource_name), data: { confirm: "Are you sure?" }, method: :delete, class: "btn btn-link" %>'
              '</div>'
  gsub_file("app/views/devise/registrations/edit.html.erb", link_to, button_to)

  environment 'config.action_mailer.default_url_options = { host: "localhost", port: 3000 }', env: "development"
  environment 'config.action_mailer.default_url_options = { host: "www.example.com" }', env: "test"
  environment 'config.action_mailer.default_url_options = { host: ENV.fetch("APP_HOST", "your_production_domain.com") }', env: "production"
end

# 7. Set up UI elements like pages, navbar, and flashes.
def setup_ui
  # Set the root route, removing any existing root to avoid conflicts.
  gsub_file "config/routes.rb", /^\s*root.*\n/, ""
  route 'root to: "pages#home"'

  file "app/controllers/pages_controller.rb", <<~RUBY, force: true
    class PagesController < ApplicationController
      skip_before_action :authenticate_user!, only: [ :home ]

      def home
      end
    end
  RUBY

  file "app/views/shared/_flashes.html.erb", <<~ERB, force: true
    <% if notice %>
      <div class="bg-blue-100 border border-blue-400 text-blue-700 px-4 py-3 rounded relative m-3" role="alert">
        <span class="block sm:inline"><%= notice %></span>
        <span class="absolute top-0 bottom-0 right-0 px-4 py-3">
          <svg class="fill-current h-6 w-6 text-blue-500" role="button" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20"><title>Close</title><path d="M14.348 14.849a1.2 1.2 0 0 1-1.697 0L10 11.819l-2.651 3.029a1.2 1.2 0 1 1-1.697-1.697l2.758-3.15-2.759-3.152a1.2 1.2 0 1 1 1.697-1.697L10 8.183l2.651-3.031a1.2 1.2 0 1 1 1.697 1.697l-2.758 3.152 2.758 3.15a1.2 1.2 0 0 1 0 1.698z"/></svg>
        </span>
      </div>
    <% end %>
    <% if alert %>
      <div class="bg-orange-100 border border-orange-400 text-orange-700 px-4 py-3 rounded relative m-3" role="alert">
        <span class="block sm:inline"><%= alert %></span>
        <span class="absolute top-0 bottom-0 right-0 px-4 py-3">
          <svg class="fill-current h-6 w-6 text-orange-500" role="button" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20"><title>Close</title><path d="M14.348 14.849a1.2 1.2 0 0 1-1.697 0L10 11.819l-2.651 3.029a1.2 1.2 0 1 1-1.697-1.697l2.758-3.15-2.759-3.152a1.2 1.2 0 1 1 1.697-1.697L10 8.183l2.651-3.031a1.2 1.2 0 1 1 1.697 1.697l-2.758 3.152 2.758 3.15a1.2 1.2 0 0 1 0 1.698z"/></svg>
        </span>
      </div>
    <% end %>
  ERB

  run "curl -L https://raw.githubusercontent.com/nicopeltier/rails-template/refs/heads/master/_navbar_tailwinds_np.html.erb > app/views/shared/_navbar.html.erb"
  
  # Add Preline Stimulus controller to navbar
  gsub_file "app/views/shared/_navbar.html.erb", 
            '<nav class="bg-white shadow-lg">', 
            '<nav class="bg-white shadow-lg" data-controller="preline">'







  inject_into_file "app/views/layouts/application.html.erb", after: "<body>\n" do
    <<~HTML
      <%= render "shared/flashes" %>
      <%= render "shared/navbar" %>
    HTML
  end

  # Wrap the main content in a Tailwind container.
  gsub_file "app/views/layouts/application.html.erb",
            "<%= yield %>",
            <<~HTML
              <div class="container mx-auto px-4">
                <%= yield %>
              </div>
            HTML

  file "app/views/pages/home.html.erb", <<~HTML, force: true
    <div class="container text-center py-5">
      <h1>Welcome to Your App</h1>
      <p>This is the home page.</p>
    </div>
  HTML
end

# 8. Install and configure Trestle for admin interface.
def setup_trestle
  generate "trestle:install"
  generate "trestle:resource", "User"
end

# --- Main Execution ---

# 1. Setup gems and bundle.
setup_gemfile
run "bundle install"

# 2. Setup Simple Form without Bootstrap.
generate "simple_form:install" unless File.exist?("config/initializers/simple_form.rb")

# 3. Setup Node.js, esbuild, PostCSS, and all JS/CSS files.
setup_node_bundling

# 4. Setup Rails configs, Devise, Trestle, and UI elements.
setup_rails_config
setup_devise
setup_trestle
setup_ui

# 5. Finalize setup: Lock platform, create .env, update .gitignore.
run "bundle lock --add-platform x86_64-linux"
run "touch '.env'"

append_to_file ".gitignore", <<~TXT

  # Ignore Node dependencies and compiled assets.
  /node_modules
  /app/assets/builds/*
  !/app/assets/builds/.keep
TXT

# 6. Forcefully overwrite package.json to ensure correct build scripts.
# This is the definitive fix that prevents jsbundling-rails from overriding our settings.
file "package.json", <<~JSON, force: true
{
  "name": "app",
  "private": true,
  "dependencies": {
    "@hotwired/stimulus": "^3.2.2",
    "@hotwired/turbo-rails": "^8.0.4",
    "esbuild": "^0.25.9",
    "preline": "^3.2.3"
  },
  "scripts": {
    "build": "esbuild app/javascript/application.js --bundle --sourcemap --outdir=app/assets/builds --log-level=error",
    "build:css": "tailwindcss -i ./app/assets/stylesheets/application.tailwind.css -o ./app/assets/builds/application.css"
  },
  "devDependencies": {
    "@tailwindcss/forms": "^0.5.7",
    "@tailwindcss/typography": "^0.5.10",
    "autoprefixer": "^10.4.17",
    "postcss": "^8.4.35",
    "postcss-cli": "^11.0.0",
    "tailwindcss": "^3.4.0"
  },
  "engines": {
    "node": "20.x",
    "npm": "10.x"
  }
}
JSON

# 7. Ensure clean npm environment and run builds
run "rm -f yarn.lock .yarnrc*" # Final cleanup of any Yarn files
run "npm install" # Ensure all dependencies are installed
run "npm run build"
run "npm run build:css"

after_bundle do
  rails_command "db:create"
  rails_command "db:migrate"

  # Initialize Git and make the first commit.
  git :init
  git add: "."
  git commit: %q(-m "Initial commit: Setup Rails 8 with Propshaft, Devise, and JS/CSS bundling")

  say "\n✅ Template applied successfully!", :green
  say "🚀 Your new Rails app is ready. Start the server with: bin/dev", :cyan
end
