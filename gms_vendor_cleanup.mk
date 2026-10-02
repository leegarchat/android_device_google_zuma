# Avoid installing older device-vendor copies of packages supplied by full GMS.

ifneq ($(filter DeviceIntelligenceNetworkPrebuiltAstrea,$(PRODUCT_PACKAGES)),)
PRODUCT_PACKAGES -= \
    DeviceIntelligenceNetworkPrebuiltAstreaPixel
endif

ifneq ($(filter DevicePersonalizationAiAiPrebuiltPixel2025,$(PRODUCT_PACKAGES)),)
PRODUCT_PACKAGES -= \
    DevicePersonalizationAiAiPrebuiltPixel2023
endif