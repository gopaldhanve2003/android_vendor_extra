# GApps
ifeq ($(WITH_GMS),true)
$(call inherit-product, vendor/gapps/arm64/arm64-vendor.mk)
endif

# Overlay
ifeq ($(WITH_GMS), true)
PRODUCT_PACKAGES += \
    ExtraUpdaterOverlay_GMS
else
PRODUCT_PACKAGES += \
    ExtraUpdaterOverlay
endif
