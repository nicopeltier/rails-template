```ruby
# frozen_string_literal: true
# =============================================================================
# Rails Template — devise.rb
# Objectif : générer une app Rails 8.0.2 prête à l’emploi avec :
#  - Ruby 3.4.5
#  - Propshaft 1.2.1 (sans Sprockets) en mode “manifest”
#  - jsbundling-rails + cssbundling-rails avec NPM
#  - Bootstrap + Popper via NPM (pas de gem bootstrap)
#  - Devise installé et configuré
#  - Compatible Heroku (précompilation Node + Ruby)
#
# IMPORTANT — Comment utiliser ce template :
#   rails new \
#     -d postgresql \
#     -m PATH/TO/devise.rb \
#     YOUR_APP_NAME
#
# (Le template fait le nécessaire pour installer jsbundling/cssbundling,
#  configurer NPM, Propshaft, Bootstrap, et Devise.)
# =============================================================================

# -----------------------------------------------------------------------------#
# Versions cibles (tu peux les modifier ici si besoin).
# -----------------------------------------------------------------------------#
RUBY_TARGET       = "3.4.5"   # Version de Ruby à fixer dans Gemfile et .ruby-version.
RAILS_TARGET      = "8.0.2"   # Version de Rails à verrouiller dans Gemfile.
PROPSHAFT_VERSION = "1.2.1"   # version de Propshaft (on épingle pour éviter les surprises).

# -----------------------------------------------------------------------------#
# 1) Nettoyage Spring (optionnel mais évite des soucis de cache pendant le setup)
#    Explication : Spring garde des processus Ruby en mémoire. On le tue pour
#    éviter d'utiliser des versions obsolètes pendant la génération.
# -----------------------------------------------------------------------------#
run "pgrep -f spring | xargs -r kill -9 || true"

# -----------------------------------------------------------------------------#
# 2) .ruby-version — force la même version localement (rbenv/asdf/rvm la liront)
# -----------------------------------------------------------------------------#
file ".ruby-version", RUBY_TARGET

# -----------------------------------------------------------------------------#
# 3) Gemfile — on impose nos versions et on prépare l’app côté Ruby.
#    - rails '8.0.2' pour coller à la contrainte
#    - propshaft '1.2.1' et on s’assure d’aucun sprockets
#    - devise pour l’authentification
#    - jsbundling-rails / cssbundling-rails pour compiler via NPM
#    - on retire importmap-rails si généré par défaut (inutile avec jsbundling)
# -----------------------------------------------------------------------------#
# S’assure qu’une directive ruby "x.y.z" existe et la remplace/insère.
if File.read("Gemfile") =~ /^ruby /
  gsub_file "Gemfile", /^ruby .*\n/, %(ruby "#{RUBY_TARGET}"\n)
else
  inject_into_file "Gemfile", %(ruby "#{RUBY_TARGET}"\n), after: "source \"https://rubygems.org\"\n"
end

# Verrouille la version de Rails.
gsub_file "Gemfile", /^gem ["']rails["'].*$/, %(gem "rails", "#{RAILS_TARGET}")

# Retire Sprockets & importmap s’ils existent (on ne veut pas de conflits).
gsub_file "Gemfile", /^gem ["']sprockets-rails["'].*\n/, ""
gsub_file "Gemfile", /^gem ["']importmap-rails["'].*\n/, ""

# Ajoute nos gems clés (en respectant la structure du Gemfile par défaut).
append_to_file "Gemfile", <<~RUBY

  # --- Authentification ---
  gem "devise"                            # Gem d'authentification éprouvée (génère User, contrôleurs, vues, etc.)

  # --- Asset pipeline moderne (sans Sprockets) ---
  gem "propshaft", "#{PROPSHAFT_VERSION}" # Pipeline d'assets de Rails 8 (digest + manifest). On épingle la version.

  # --- Bundling via Node/NPM ---
  gem "jsbundling-rails"                  # Branche les bundles JS (esbuild/rollup/webpack) sur la précompilation Rails
  gem "cssbundling-rails"                 # Idem pour le CSS (Sass/PostCSS/Bootstrap/Bulma/Tailwind via Node)
RUBY

# Rappels :
# - pg, puma, bootsnap… sont déjà présents dans le Gemfile initial de Rails 8.
# - On n’ajoute PAS la gem 'bootstrap'. On prendra Bootstrap depuis NPM (demande).
# - On n’ajoute PAS 'sass-rails' / 'sassc-rails' (héritage Sprockets) pour éviter les conflits.

# -----------------------------------------------------------------------------#
# 4) Bundle install — installe les gems ci-dessus.
# -----------------------------------------------------------------------------#
run "bundle install"

# -----------------------------------------------------------------------------#
# 5) Node / NPM — on force NPM (pas yarn) et on installe les outils côté JS/CSS.
#    Explications :
#      - jsbundling-rails installe un bundler (on choisit esbuild pour la simplicité).
#      - cssbundling-rails installe un preset (on choisit bootstrap).
#      - on ajoute bootstrap + @popperjs/core via NPM (pas de gem bootstrap).
# -----------------------------------------------------------------------------#
# On évite que Yarn soit choisi par défaut si présent sur la machine.
run "rm -f yarn.lock"

# Initialise package.json si absent (rails peut ne pas l’avoir créé).
run "npm init -y" unless File.exist?("package.json")

# Installe et configure le bundler JS (esbuild).
run "bin/rails javascript:install:esbuild"

# Installe et configure le bundler CSS en mode Bootstrap (via Sass CLI).
run "bin/rails css:install:bootstrap"

# Ajoute Bootstrap & Popper côté JS pour les composants interactifs (dropdowns, modals…)
run "npm install bootstrap @popperjs/core"

# Ajuste les scripts NPM pour correspondre à la demande : `npm run build` et `npm run build:css`
# - build     : bundle JS → app/assets/builds (pris ensuite par Propshaft)
# - build:css : compile SCSS Bootstrap → app/assets/builds/application.css
run %(npm pkg set scripts.build="esbuild app/javascript/*.* --bundle --sourcemap --outdir=app/assets/builds --public-path=/assets")
# Le preset Bootstrap a déjà créé build:css, on l’écrase pour s’assurer du format souhaité et des paths propres:
run %(npm pkg set scripts."build:css"="sass ./app/assets/stylesheets/application.bootstrap.scss:./app/assets/builds/application.css --no-source-map")

# -----------------------------------------------------------------------------#
# 6) JS d’entrée — on charge Bootstrap côté JS (pour tooltips/modals, etc.)
#    Explication : import "bootstrap" activera la partie JS de Bootstrap (qui
#    dépend de Popper pour certains composants).
# -----------------------------------------------------------------------------#
application_js_path = "app/javascript/application.js"
append_to_file application_js_path, %(\n// Active les composants JS de Bootstrap\nimport "bootstrap"\n)

# -----------------------------------------------------------------------------#
# 7) Propshaft — configuration “manifest-only” en production.
#    Idée clé : en dev, Propshaft sert les assets via le load path.
#               en prod, après `assets:precompile`, il s’appuie sur le MANIFEST
#               (public/assets/.manifest.json) : c’est ce que tu veux.
#    Actions :
#     - Ajout de app/assets/builds au chemin d’assets (où js/css bundlés sortent)
#     - Exclusion des dossiers sources pour éviter les doublons en prod
#       (on ne veut pas que les SCSS/JS sources soient copiés tels quels).
# -----------------------------------------------------------------------------#
initializer "assets.rb", <<~RUBY
  # Be sure to restart your server when you modify this file.

  # Version des assets (utile pour invalider le cache si besoin)
  Rails.application.config.assets.version = "1.0"

  # Où JS/CSS compilés par les bundlers sont déposés (puis digérés par Propshaft)
  Rails.application.config.assets.paths << Rails.root.join("app/assets/builds")

  # Exclut les sources de compilation du load path pour éviter les doublons en prod
  # Explication : nos SCSS (source) sont transformés en 1 fichier CSS final dans builds/.
  # Idem pour le JS. On demande donc à Propshaft d'ignorer les dossiers de sources.
  Rails.application.config.assets.excluded_paths << Rails.root.join("app/javascript")
  Rails.application.config.assets.excluded_paths << Rails.root.join("app/assets/stylesheets")
RUBY

# Production : on clarifie qu’on ne doit JAMAIS compiler à la volée.
gsub_file "config/environments/production.rb",
          /#?\s*config\.assets\.compile\s*=.*\n?/,
          "config.assets.compile = false\n"
append_to_file "config/environments/production.rb", <<~RUBY

  # Propshaft en mode manifest (comportement par défaut après précompilation) :
  # - Les fichiers sont servis via le mapping .manifest.json
  # - Assure des URLs fingerprintées et un cache long
  # Heroku: le build Ruby lancera `assets:precompile` qui déclenche `npm run build`
  # et `npm run build:css` grâce aux gems *bundling-rails.
RUBY

# -----------------------------------------------------------------------------#
# 8) Layout — on s’assure que les helpers appellent les bundles Propshaft.
#    - stylesheet_link_tag "application"         → prend app/assets/builds/application.css
#    - javascript_include_tag "application"      → prend app/assets/builds/application.js
#    - data-turbo-track="reload"                 → rechargement auto si l’asset change
# -----------------------------------------------------------------------------#
gsub_file "app/views/layouts/application.html.erb",
          /<%= stylesheet_link_tag .* %>/,
          %(<%= stylesheet_link_tag "application", "data-turbo-track": "reload" %>)
gsub_file "app/views/layouts/application.html.erb",
          /<%= javascript_include_tag .* %>/,
          %(<%= javascript_include_tag "application", "data-turbo-track": "reload", defer: true %>)

# Si le layout par défaut n’a pas de tags (cas rares), on les insère proprement.
layout_path = "app/views/layouts/application.html.erb"
if File.exist?(layout_path) && !File.read(layout_path).include?("stylesheet_link_tag")
  inject_into_file layout_path,
    %(\n    <%= stylesheet_link_tag "application", "data-turbo-track": "reload" %>\n),
    after: /<head>.*\n/
end
if File.exist?(layout_path) && !File.read(layout_path).include?("javascript_include_tag")
  inject_into_file layout_path,
    %(\n    <%= javascript_include_tag "application", "data-turbo-track": "reload", defer: true %>\n),
    before: %r{</head>}
end

# -----------------------------------------------------------------------------#
# 9) Devise — installation + modèle User + config des URLs par environnement.
#    Explications :
#      - devise:install crée les fichiers de config et routes nécessaires.
#      - devise User te donne un modèle d’utilisateur prêt à l’emploi.
#      - default_url_options est nécessaire pour générer des liens complets
#        (ex : emails de confirmation) en dev/test/prod.
# -----------------------------------------------------------------------------#
generate "devise:install"
generate "devise", "User"

# Ajoute un host par défaut pour les URLs (development/test).
environment 'config.action_mailer.default_url_options = { host: "localhost", port: 3000 }', env: "development"
environment 'config.action_mailer.default_url_options = { host: "www.example.com" }', env: "test"

# En production, on lit le host depuis ENV (compatible Heroku).
environment <<~RUBY, env: "production"
  config.action_mailer.default_url_options = {
    host: ENV.fetch("APP_HOST") { "example.com" },
    protocol: "https"
  }
RUBY

# -----------------------------------------------------------------------------#
# 10) Flashes — un partial simple + inclusion dans le layout.
#      (Bootstrap gère les styles .alert .alert-info/success/warning/danger)
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

# Insère le render des flashes juste après l’ouverture du <body>.
if File.exist?(layout_path) && !File.read(layout_path).include?('render "shared/flashes"')
  gsub_file layout_path,
            /<body[^>]*>/,
            "\\0\n    <%= render \"shared/flashes\" %>"
end

# -----------------------------------------------------------------------------#
# 11) Page d’accueil minimale — pour vérifier rapidement que tout marche.
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
# 12) Procfile (Heroku) — Puma en production.
#     Explication : Heroku détecte Rails mais déclarer Puma explicitement est sain.
# -----------------------------------------------------------------------------#
file "Procfile", <<~YAML
  web: bundle exec puma -C config/puma.rb
YAML

# -----------------------------------------------------------------------------#
# 13) Gitignore — on ignore les builds et node_modules; on garde un .keep.
# -----------------------------------------------------------------------------#
append_to_file ".gitignore", <<~TXT

  # --- Node & builds (générés par js/css bundling) ---
  /node_modules
  /app/assets/builds/*
  !/app/assets/builds/.keep
TXT
run "mkdir -p app/assets/builds && touch app/assets/builds/.keep"

# -----------------------------------------------------------------------------#
# 14) Base de données — création et migration devise (User).
# -----------------------------------------------------------------------------#
rails_command "db:create"
rails_command "db:migrate"

# -----------------------------------------------------------------------------#
# 15) Préparation finale — on construit les assets une première fois (dev).
#     Tu pourras relancer en local :
#       npm run build
#       npm run build:css
# -----------------------------------------------------------------------------#
run "npm run build"
run "npm run build:css"

# -----------------------------------------------------------------------------#
# 16) Commit initial (optionnel) — pratique pour repartir propre.
# -----------------------------------------------------------------------------#
after_bundle do
  git :init
  git add: "."
  git commit: %q(-m "Initial commit: Rails 8.0.2 + Propshaft 1.2.1 + js/css bundling (NPM) + Bootstrap + Devise")
end

# =============================================================================
# Notes pédagogiques (rappel) :
# - Propshaft sert les assets : en dev depuis les paths (load path), en prod
#   via un manifest (.manifest.json) généré par `rails assets:precompile`.
# - jsbundling-rails/cssbundling-rails branchent `npm run build` et `npm run build:css`
#   automatiquement sur `assets:precompile`. Sur Heroku, la build Ruby exécutera
#   ces scripts si le buildpack Node est présent avant le buildpack Ruby.
# - On n’utilise pas la gem bootstrap (évite les conflits Sprockets). Tout passe
#   par NPM → propshaft → helpers (`stylesheet_link_tag`/`javascript_include_tag`).
# =============================================================================
```
