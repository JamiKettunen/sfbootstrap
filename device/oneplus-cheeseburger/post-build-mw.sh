# Additional MW for extra functionality on OnePlus 5/5T devices
sfb_build_packages --mw=https://github.com/sailfishos-oneplus5/triambience-daemon.git && \
sfb_build_packages --mw=https://github.com/sailfishos-oneplus5/onyx-triambience-settings-plugin.git && \
sfb_build_packages --mw=https://github.com/sailfishos-oneplus5/gesture-daemon.git && \
sfb_build_packages --mw=https://github.com/sailfishos-oneplus5/onyx-gesture-settings-plugin.git && \
sfb_build_packages --mw=sailfish-fpd-community --spec=rpm/droid-biometry-fp.spec --spec=rpm/sailfish-fpd-community.spec
