# Additional MW for extra functionality on Xiaomi MI 6 devices
sfb_build_packages --mw=https://github.com/mentaljam/harbour-storeman.git && \
sfb_build_packages --mw=sailfish-fpd-community --spec=rpm/droid-biometry-fp.spec --spec=rpm/sailfish-fpd-community.spec
