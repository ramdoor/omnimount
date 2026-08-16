# Omnimount — atajos de desarrollo e instalación.
# En Apple Silicon /opt/homebrew pertenece al usuario: no hace falta sudo.
PREFIX ?= /opt/homebrew
# Compilar fuera del árbol del repo (evita saturar carpetas sincronizadas).
SCRATCH ?= $(HOME)/.omnimount-build

# Identidad de firma: con una identidad estable, el permiso de Acceso total
# al disco (TCC) sobrevive a las recompilaciones. Detecta la primera identidad
# de desarrollo disponible; si no hay, firma ad-hoc ("-").
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F '"' 'NR==1 {print $$2}')
ifeq ($(SIGN_ID),)
SIGN_ID := -
endif

.PHONY: build test app install install-cli fuse2fs clean

build:
	swift build --scratch-path $(SCRATCH)

test:
	swift test --scratch-path $(SCRATCH)

app:
	./scripts/make-app.sh

install-cli:
	swift build -c release --scratch-path $(SCRATCH)
	install -m 755 $(SCRATCH)/release/omnimount $(PREFIX)/bin/omnimount
	codesign --force --sign "$(SIGN_ID)" $(PREFIX)/bin/omnimount
	@echo "CLI instalado en $(PREFIX)/bin/omnimount (firmado: $(SIGN_ID))"

install: install-cli app
	rm -rf /Applications/Omnimount.app
	cp -R dist/Omnimount.app /Applications/
	@echo "App instalada en /Applications/Omnimount.app"
	@echo "Recuerda: si el helper estaba activo, reinícialo:"
	@echo "  sudo launchctl kickstart -k system/org.omnimount.helper"

fuse2fs:
	./scripts/build-fuse2fs.sh
	@if [ -f vendor/bin/fuse2fs ]; then install -m 755 vendor/bin/fuse2fs $(PREFIX)/sbin/fuse2fs 2>/dev/null && echo "fuse2fs instalado en $(PREFIX)/sbin/fuse2fs" || true; fi

clean:
	swift package clean --scratch-path $(SCRATCH) 2>/dev/null || true
	rm -rf dist
