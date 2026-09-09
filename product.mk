# Overlay
ifeq ($(WITH_GMS), true)
PRODUCT_PACKAGES += \
    ExtraUpdaterOverlay_GMS
else
PRODUCT_PACKAGES += \
    ExtraUpdaterOverlay
endif
