ifneq ($(BUILD_VANILLA), true)

# Pixel
$(call inherit-product, vendor/pixel/clocks/products/clocks.mk)
$(call inherit-product, vendor/pixel/gms/products/gms.mk)
$(call inherit-product, vendor/pixel/gsans/products/gsans.mk)
$(call inherit-product, vendor/pixel/launcher/products/launcher.mk)

endif

# Face Unlock
TARGET_FACE_UNLOCK_SUPPORTED ?= true

ifeq ($(TARGET_FACE_UNLOCK_SUPPORTED),true)
PRODUCT_PACKAGES += \
    FaceUnlock

PRODUCT_SYSTEM_EXT_PROPERTIES += \
    ro.face.sense_service=true

PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.biometrics.face.xml:$(TARGET_COPY_OUT_SYSTEM)/etc/permissions/android.hardware.biometrics.face.xml
endif

# Overlay
ifneq ($(BUILD_VANILLA), true)
PRODUCT_PACKAGES += \
    ExtraSettingsResTarget \
    ExtraUpdaterOverlay_GMS
endif

PRODUCT_PACKAGES += \
    ExtraUpdaterOverlay \
    ExtraPIFrameworksResTarget
