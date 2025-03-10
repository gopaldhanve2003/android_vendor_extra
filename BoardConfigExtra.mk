ifneq ($(BUILD_VANILLA), true)

# Pixel
include vendor/pixel/clocks/products/board.mk
include vendor/pixel/gms/products/board.mk
include vendor/pixel/gsans/products/board.mk
include vendor/pixel/launcher/products/board.mk

endif

# Sepolicy
SYSTEM_EXT_PRIVATE_SEPOLICY_DIRS += \
    vendor/extra/sepolicy/private
