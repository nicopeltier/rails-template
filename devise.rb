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

# 3. Create .railsrc to configure Rails installer options.
# This must be done at the top to ensure it's available for subsequent commands.
file ".railsrc", "--skip-spring\n--javascript=npm\n"

# 4. Configure Gemfile for Rails 8, Propshaft, and Bundling.
def setup_gemfile
  # Drop the database to ensure a clean slate, ignoring errors if it doesn't exist.
  run "rails db:drop || true"
  # Force npm as the JavaScript installer by creating a package.json file.
  # This makes the bundler installers default to npm instead of yarn.
  file "package.json", "{}"
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
  run "npm init -y" unless File.exist?("package.json")
  run "bin/rails javascript:install:esbuild"
  run "bin/rails css:install:bootstrap"
  # Explicitly install ALL node dependencies to bypass the faulty generators.
  # This ensures esbuild, sass, and postcss are available in node_modules/.bin.
  run "npm install esbuild sass postcss-cli autoprefixer bootstrap @popperjs/core"

  # Define npm scripts for building JS and CSS without running them.
  # The final build will be triggered once at the end of the template.
  run %(npm pkg set scripts.build="./node_modules/.bin/esbuild app/javascript/*.* --bundle --sourcemap --outdir=app/assets/builds --public-path=/assets")
  run %(npm pkg set scripts.build:css:compile="./node_modules/.bin/sass ./app/assets/stylesheets/application.bootstrap.scss:./app/assets/builds/application.css --no-source-map --load-path=node_modules")
  run %(npm pkg set scripts.build:css:prefix="./node_modules/.bin/postcss ./app/assets/builds/application.css --use=autoprefixer --output=./app/assets/builds/application.css")
  run %(npm pkg set scripts.build:css="npm run build:css:compile && npm run build:css:prefix")

  # Update the application layout to use the bundled assets instead of importmaps.
  layout_path = "app/views/layouts/application.html.erb"
  gsub_file layout_path, /<%= stylesheet_link_tag .*%>/, '<%= stylesheet_link_tag "application", "data-turbo-track": "reload" %>'
  gsub_file layout_path, /<%= javascript_importmap_tags .*%>.*$/, '<%= javascript_include_tag "application", "data-turbo-track": "reload", defer: true %>'
  gsub_file layout_path, /<%= javascript_include_tag .*%>/, '<%= javascript_include_tag "application", "data-turbo-track": "reload", defer: true %>'
end

# 5. Configure Propshaft and Rails generators.
def setup_rails_config
  initializer "assets.rb", <<~RUBY
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

  run "curl -L https://raw.githubusercontent.com/nicopeltier/rails-template/refs/heads/master/_navbar_np.html.erb > app/views/shared/_navbar.html.erb"







  inject_into_file "app/views/layouts/application.html.erb", after: "<body>\n" do
    <<~HTML
      <%= render "shared/flashes" %>
      <%= render "shared/navbar" %>
    HTML
  end

  # Wrap the main content in a Bootstrap container.
  gsub_file "app/views/layouts/application.html.erb",
            "<%= yield %>",
            <<~HTML
              <div class="container">
                <div class="row">
                  <div class="col">
                    <%= yield %>
                  </div>
                </div>
              </div>
            HTML

  file "app/views/pages/home.html.erb", <<~HTML
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

setup_gemfile
run "bundle install"

generate "simple_form:install", "--bootstrap" unless File.exist?("config/initializers/simple_form_bootstrap.rb")

setup_node_bundling
append_to_file "app/javascript/application.js", %(\n// Import and start all Bootstrap JS\nimport "bootstrap"\n)

setup_rails_config
setup_devise
setup_trestle
setup_ui

# Finalize setup
# ----------------------------------------
run "bundle lock --add-platform x86_64-linux"
run "touch '.env'"

append_to_file ".gitignore", <<~TXT

  # Ignore Node dependencies and compiled assets.
  /node_modules
  /app/assets/builds/*
  !/app/assets/builds/.keep
TXT

file "Procfile", "web: bundle exec puma -C config/puma.rb"
run "touch app/assets/builds/.keep"

run "npm run build && npm run build:css"

after_bundle do
  rails_command "db:create"
  rails_command "db:migrate"

  git :init
  git add: "."
  git commit: %q(-m "Initial commit: Setup Rails 8 with Propshaft, Devise, and JS/CSS bundling")
  
  say "\n✅ Template applied successfully!", :green
  say "🚀 Your new Rails app is ready. Start the server with: bin/dev", :cyan
end
