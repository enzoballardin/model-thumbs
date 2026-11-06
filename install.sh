#!/bin/bash
# ModelThumbs no longer installs through `curl | bash`. This script is kept so the old
# command prints the new instructions instead of failing silently. It changes nothing.

cat <<'EOF'
ModelThumbs now installs from a tagged release with make, so you can read what it
will do before it runs. In Terminal:

  git clone https://github.com/enzoballardin/model-thumbs.git
  cd model-thumbs
  git checkout "$(git describe --tags --abbrev=0)"
  make build install

For STEP / IGES / BREP thumbnails, run `brew install opencascade` first and use
`make build CAD=1 install`. Run `make -n <target>` to see any step's commands first.

If you installed with this script before, remove that copy first:

  make uninstall PREFIX=/Applications
  rm -rf ~/.modelthumbs

Details: https://github.com/enzoballardin/model-thumbs#installation
EOF
exit 1
