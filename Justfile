# Render all environments
render-all: render-lab

# Render lab environment
render-lab:
    rm -rf manifests/lab/*
    tk export manifests/lab/ environments/lab --format '{{ "{{" }}.metadata.name{{ "}}" }}-{{ "{{" }}.kind | lower{{ "}}" }}'

# Initialize jsonnet-bundler dependencies
jb-install:
    jb install

# Update jsonnet-bundler dependencies
jb-update:
    jb update

# Show diff of what would change in lab
diff-lab:
    tk diff environments/lab
