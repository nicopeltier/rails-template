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
#   - jsbundling-rails + cssbundling-rails (with esbuild and Sass/Bootstrap)
#   - Devise for authentication
#   - Simple Form with Bootstrap wrappers
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
file ".ruby-version", RUBY_VERSION

# 3. Configure Gemfile for Rails 8, Propshaft, and Bundling.
#    - Pin key versions for consistency.
#    - Remove conflicting gems like importmap-rails and sprockets-rails.
#    - Add gems for authentication, forms, and asset bundling.
def setup_gemfile
  # Set Ruby version
  gsub_file "Gemfile", /^ruby .*/, %(ruby "#{RUBY_VERSION}")

  # Pin Rails version
  gsub_file "Gemfile", /^gem "rails", .*/, %(gem "rails", "#{RAILS_VERSION}")

  # Remove gems we are replacing
  gsub_file "Gemfile", /^\s*# Use JavaScript with ESM import maps.*\n/, ""
  gsub_file "Gemfile", /^\s*gem "importmap-rails".*\n/, ""
  gsub_file "Gemfile", /^\s*gem "sprockets-rails".*\n/, ""

  # Ensure Propshaft is correctly configured and pinned
  if File.read("Gemfile").match?(/gem "propshaft"/)
    gsub_file "Gemfile", /gem "propshaft".*/, %(gem "propshaft", "#{PROPSHAFT_VERSION}")
  else
    append_to_file "Gemfile", %(\ngem "propshaft", "#{PROPSHAFT_VERSION}"\n)
  end

  # Add core gems for our stack
  append_to_file "Gemfile", <<~RUBY

    # --- Authentication & Forms ---
    gem "devise"
    gem "simple_form"

    # --- Asset Bundling (replaces importmap/sprockets) ---
    gem "jsbundling-rails"
    gem "cssbundling-rails"
  RUBY
end

setup_gemfile

# 4. Install all gems.
run "bundle install"

# We install Simple Form with Bootstrap wrappers once; if already present, skip.
unless File.exist?("config/initializers/simple_form.rb") || File.exist?("config/initializers/simple_form_bootstrap.rb")
  generate "simple_form:install", "--bootstrap"
end


# 5. Set up Node.js for asset bundling.
#    - Enforce NPM over Yarn.
#    - Install esbuild for JS and Sass/Bootstrap for CSS.
#    - Configure build scripts in package.json.
def setup_node_bundling
  # Ensure NPM is used
  run "rm -f yarn.lock"
  run "npm init -y" unless File.exist?("package.json")

  # Install bundlers
  run "bin/rails javascript:install:esbuild"
  run "bin/rails css:install:bootstrap" # Uses the Sass CLI preset

  # Install Bootstrap JS dependencies
  run "npm install bootstrap @popperjs/core"

  # Define build scripts in package.json
  run %(npm pkg set scripts.build="esbuild app/javascript/*.* --bundle --sourcemap --outdir=app/assets/builds --public-path=/assets")
  run %(npm pkg set scripts."build:css"="sass ./app/assets/stylesheets/application.bootstrap.scss:./app/assets/builds/application.css --no-source-map --load-path=node_modules")
end

setup_node_bundling

# 6. Configure Propshaft.
#    - Create an initializer to define asset paths.
#    - Ensure production environment uses precompiled assets only.
def setup_propshaft
  initializer "assets.rb", <<~RUBY
    # Be sure to restart your server when you modify this file.
    Rails.application.config.assets.version = "1.0"

    # Add the folder with our compiled assets to Propshaft's search path.
    Rails.application.config.assets.paths << Rails.root.join("app/assets/builds")

    # Exclude source asset directories to prevent Propshaft from serving them directly.
    Rails.application.config.assets.excluded_paths << Rails.root.join("app/javascript")
    Rails.application.config.assets.excluded_paths << Rails.root.join("app/assets/stylesheets")
  RUBY

  # Disable on-the-fly compilation in production for performance and security.
  gsub_file "config/environments/production.rb",
            /#?\s*config\.assets\.compile\s*=.*/,
            "config.assets.compile = false"
end

setup_propshaft

# 7. Update layout to include bundled assets.
#    - Replace default helpers with ones pointing to our build outputs.
def update_layout
  layout_path = "app/views/layouts/application.html.erb"
  return unless File.exist?(layout_path)

  gsub_file layout_path,
            /<%= stylesheet_link_tag .*%>/,
            '<%= stylesheet_link_tag "application", "data-turbo-track": "reload" %>'

  gsub_file layout_path,
            /<%= javascript_importmap_tags .*%>.*$/,
            '<%= javascript_include_tag "application", "data-turbo-track": "reload", defer: true %>'
  
  gsub_file layout_path,
            /<%= javascript_include_tag .*%>/,
            '<%= javascript_include_tag "application", "data-turbo-track": "reload", defer: true %>'
end

update_layout


# Generators
########################################
generators = <<~RUBY
  config.generators do |generate|
    generate.assets false
    generate.helper false
    generate.test_framework :test_unit, fixture: false
  end
RUBY

environment generators

# General Config
########################################
general_config = <<~RUBY
  config.action_controller.raise_on_missing_callback_actions = false if Rails.version >= "7.1.0"
RUBY

environment general_config

# 8. Import Bootstrap JavaScript in the entrypoint.
append_to_file "app/javascript/application.js", %(\n// Import and start all Bootstrap JS\nimport "bootstrap"\n)

# 9. Install and configure Devise.
#    - Run installers and generators idempotently.
#    - Harden the migration to be safely re-runnable.
def setup_devise
  # Install Devise if the initializer is missing.
  generate "devise:install" unless File.exist?("config/initializers/devise.rb")

  # Generate User model only if it doesn't exist.
  unless File.exist?("app/models/user.rb")
    generate "devise", "User"
  end

  # Make the Devise migration robust for re-runs.
  devise_migration = Dir.glob("db/migrate/*_devise_create_users.rb").first
  if devise_migration
    gsub_file devise_migration, /create_table :users do/, 'create_table :users, if_not_exists: true do'
    gsub_file devise_migration, /(add_index.*)/, 'add_index :users, :email, unique: true, if_not_exists: true'
    gsub_file devise_migration, /(add_index.*)/, 'add_index :users, :reset_password_token, unique: true, if_not_exists: true'
  end

# Application controller
  ########################################
  run "rm app/controllers/application_controller.rb"
  file "app/controllers/application_controller.rb", <<~RUBY
    class ApplicationController < ActionController::Base
      before_action :authenticate_user!
    end
  RUBY

  # migrate + devise views
  ########################################
  rails_command "db:migrate"
  generate("devise:views")

  link_to = <<~HTML
    <p>Unhappy? <%= link_to "Cancel my account", registration_path(resource_name), data: { confirm: "Are you sure?" }, method: :delete %></p>
  HTML
  button_to = <<~HTML
    <div class="d-flex align-items-center">
      <div>Unhappy?</div>
      <%= button_to "Cancel my account", registration_path(resource_name), data: { confirm: "Are you sure?" }, method: :delete, class: "btn btn-link" %>
    </div>
  HTML
  gsub_file("app/views/devise/registrations/edit.html.erb", link_to, button_to)

  # Pages Controller
  ########################################
  run "rm app/controllers/pages_controller.rb"
  file "app/controllers/pages_controller.rb", <<~RUBY
    class PagesController < ApplicationController
      skip_before_action :authenticate_user!, only: [ :home ]

      def home
      end
    end
  RUBY


  # Configure mailer URLs for each environment.
  environment 'config.action_mailer.default_url_options = { host: "localhost", port: 3000 }', env: "development"
  environment 'config.action_mailer.default_url_options = { host: "www.example.com" }', env: "test"
  environment 'config.action_mailer.default_url_options = { host: ENV.fetch("APP_HOST", "your_production_domain.com") }', env: "production"
end

setup_devise

# 10. Install Simple Form with Bootstrap wrappers.
generate "simple_form:install", "--bootstrap" unless File.exist?("config/initializers/simple_form_bootstrap.rb")

# 11. Create a home page and flash messages partial.
def setup_ui

  generate :controller, "pages", "home", "--skip-routes"
  route 'root to: "pages#home"'

  # Create a shared partial for flash messages.
  file "app/views/shared/_flashes.html.erb", <<~ERB
    <% if notice %>
      <div class="alert alert-info alert-dismissible fade show m-3" role="alert">
        <%= notice %>
        <button type="button" class="btn-close" data-bs-dismiss="alert" aria-label="Close"></button>
      </div>
    <% end %>
    <% if alert %>
      <div class="alert alert-warning alert-dismissible fade show m-3" role="alert">
        <%= alert %>
        <button type="button" class="btn-close" data-bs-dismiss="alert" aria-label="Close"></button>
      </div>
    <% end %>
  ERB

  # Render flashes in the main layout.
  inject_into_file "app/views/layouts/application.html.erb",
                   "    <%= render 'shared/flashes' %>\n",
                   after: /<body.*>\n/

 # navbar

run "curl -L https://raw.githubusercontent.com/lewagon/awesome-navbars/master/templates/_navbar_wagon.html.erb > app/views/shared/_navbar.html.erb"

inject_into_file "app/views/layouts/application.html.erb", after: "<body>" do
  <<~HTML
    <%= render "shared/navbar" %>
    <%= render "shared/flashes" %>
  HTML
end


  # Add sample content to the home page.
  append_to_file "app/views/pages/home.html.erb", <<~ERB
    <div class="container py-5">
      <h1>Welcome to Rails 8!</h1>
      <p>This app is running with Propshaft, esbuild, Bootstrap, and Devise.</p>
    </div>
  ERB




end

setup_ui


# 12. Configure Git, Procfile, and database.
append_to_file ".gitignore", <<~TXT

  # Ignore Node dependencies and compiled assets.
  /node_modules
  /app/assets/builds/*
  !/app/assets/builds/.keep
TXT

file "Procfile", "web: bundle exec puma -C config/puma.rb"
run "touch app/assets/builds/.keep"

# 13. Create database and run migrations.
rails_command "db:create"
rails_command "db:migrate"

# 14. Build assets for the first time.
run "npm run build && npm run build:css"

# 15. Finalize with a git commit.
after_bundle do
  git :init
  git add: "."
  git commit: %q(-m "Initial commit: Setup Rails 8 with Propshaft, Devise, and JS/CSS bundling")
  
  say "\n✅ Template applied successfully!", :green
  say "🚀 Your new Rails app is ready. Start the server with: bin/dev", :cyan
end
