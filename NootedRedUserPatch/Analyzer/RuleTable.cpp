// NootedRedUserPatch compiled rule table
//
// Copyright (C) 2026  ChefKiss.
//
// GENERATED from the clean 15.8.2/26.7.2 fixtures by scratch/generate_rules.py.
// The runtime never reads the fixtures or any profile; this table is the patch policy.
// See docs/USERSPACE-PATCHING.md for the rule model and shape-variant rationale.

#include <Analyzer/RuleTable.hpp>

namespace NRedUserPatch
{

    static const uint8_t kFind0a[] = {0x83, 0xE0, 0xFE};
    static const uint8_t kReplace0a[] = {0x83, 0xC8, 0x01};
    static const uint8_t kPattern0a[] = {0x00, 0xD1, 0xE9, 0x83, 0xE1, 0x01, 0x8B, 0x83, 0x98, 0x13, 0x00, 0x00, 0x83, 0xE0, 0xFE, 0x09, 0xC8, 0x89, 0x83, 0x98, 0x13, 0x00, 0x00, 0x48, 0x8B, 0x8B, 0x68};
    static const uint8_t kMask0a[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};

    static const uint8_t kFind1a[] = {0xC7, 0x47, 0x78, 0x04, 0x00, 0x00, 0x00};
    static const uint8_t kReplace1a[] = {0xC7, 0x47, 0x78, 0x01, 0x00, 0x00, 0x00};
    static const uint8_t kPattern1a[] = {0x41, 0x83, 0xF8, 0x13, 0x77, 0x45, 0xC7, 0x07, 0x8D, 0x00, 0x00, 0x00, 0xC7, 0x47, 0x78, 0x04, 0x00, 0x00, 0x00, 0xC5, 0xF8, 0x28, 0x05, 0x50, 0xFE, 0x0D, 0x00, 0xC5, 0xF8, 0x11, 0x87};
    static const uint8_t kMask1a[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1};

    static const uint8_t kFind2a[] = {0x75, 0x0B};
    static const uint8_t kReplace2a[] = {0xEB, 0x0B};
    static const uint8_t kPattern2a[] = {0x85, 0x28, 0xFE, 0xFF, 0xFF, 0xF6, 0x80, 0xA0, 0x00, 0x00, 0x00, 0x02, 0x75, 0x0B, 0x31, 0xC0, 0x4C, 0x8B, 0x9D, 0x80, 0xFE, 0xFF, 0xFF, 0xEB, 0x2C, 0x83};
    static const uint8_t kMask2a[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};
    static const uint8_t kFind2b[] = {0x74, 0x28};
    static const uint8_t kReplace2b[] = {0xEB, 0x00};
    static const uint8_t kPattern2b[] = {0xA0, 0x00, 0x00, 0x00, 0x02, 0x48, 0x8B, 0x9D, 0x70, 0xFE, 0xFF, 0xFF, 0x74, 0x28, 0x80, 0xBD, 0x80, 0xFE, 0xFF, 0xFF, 0x00, 0x0F, 0x95, 0xC0, 0x48, 0x8B};
    static const uint8_t kMask2b[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};

    static const uint8_t kFind3a[] = {0x0F, 0x94, 0xC0};
    static const uint8_t kReplace3a[] = {0x31, 0xC0, 0x90};
    static const uint8_t kPattern3a[] = {0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x49, 0x85, 0x54, 0x03, 0x08, 0x0F, 0x94, 0xC0, 0x08, 0xC8, 0x4C, 0x8B, 0xB5, 0x88, 0xFE, 0xFF, 0xFF, 0x48, 0x8B, 0xB5};
    static const uint8_t kMask3a[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};
    static const uint8_t kFind3b[] = {0x0F, 0x94, 0xC1};
    static const uint8_t kReplace3b[] = {0x31, 0xC9, 0x90};
    static const uint8_t kPattern3b[] = {0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x48, 0x85, 0x54, 0x0B, 0x08, 0x0F, 0x94, 0xC1, 0x08, 0xC1, 0x0F, 0xB6, 0xC1, 0x41, 0x8B, 0x4C, 0x24, 0x28, 0x83, 0xE1};
    static const uint8_t kMask3b[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};

    static const uint8_t kFind4a[] = {0xC7, 0x47, 0x78, 0x04, 0x00, 0x00, 0x00};
    static const uint8_t kReplace4a[] = {0xC7, 0x47, 0x78, 0x01, 0x00, 0x00, 0x00};
    static const uint8_t kPattern4a[] = {0x41, 0x83, 0xF8, 0x13, 0x77, 0x45, 0xC7, 0x07, 0x8D, 0x00, 0x00, 0x00, 0xC7, 0x47, 0x78, 0x04, 0x00, 0x00, 0x00, 0xC5, 0xF8, 0x28, 0x05, 0xD4, 0x76, 0x2F, 0x00, 0xC5, 0xF8, 0x11, 0x87};
    static const uint8_t kMask4a[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1};

    static const uint8_t kFind5a[] = {0xBB, 0x0B, 0x00, 0x00, 0x00};
    static const uint8_t kReplace5a[] = {0xBB, 0x05, 0x00, 0x00, 0x00};
    static const uint8_t kPattern5a[] = {0x75, 0x0A, 0xBB, 0x06, 0x00, 0x00, 0x00, 0xE9, 0x9B, 0xFE, 0xFF, 0xFF, 0xBB, 0x0B, 0x00, 0x00, 0x00, 0xE9, 0x91, 0xFE, 0xFF, 0xFF};
    static const uint8_t kMask5a[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};

    static const uint8_t kFind6a[] = {0x49, 0x8B, 0x85, 0x60, 0x04, 0x00, 0x00, 0x8B, 0x50, 0x0C};
    static const uint8_t kReplace6a[] = {0xBA, 0x02, 0x00, 0x00, 0x00, 0x90, 0x90, 0x90, 0x90, 0x90};
    static const uint8_t kPattern6a[] = {0x89, 0xF6, 0x49, 0x89, 0xFD, 0x48, 0x8B, 0xBF, 0x40, 0x25, 0x01, 0x00, 0x49, 0x8B, 0x85, 0x60, 0x04, 0x00, 0x00, 0x8B, 0x50, 0x0C, 0x48, 0x8B, 0x07, 0xFF, 0x50, 0x18, 0x48, 0x85, 0xC0, 0x74, 0x59, 0x48};
    static const uint8_t kMask6a[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};

    static const uint8_t kFind7a[] = {0x48, 0x8B, 0x86, 0x60, 0x04, 0x00, 0x00, 0x8B, 0x40, 0x0C};
    static const uint8_t kReplace7a[] = {0xB8, 0x02, 0x00, 0x00, 0x00, 0x90, 0x90, 0x90, 0x90, 0x90};
    static const uint8_t kPattern7a[] = {0x55, 0x48, 0x89, 0xE5, 0x41, 0x56, 0x53, 0x49, 0x89, 0xF6, 0x48, 0x8B, 0x86, 0x60, 0x04, 0x00, 0x00, 0x8B, 0x40, 0x0C, 0x8D, 0x48, 0xFF, 0x83, 0xF9, 0x02, 0x72, 0x22, 0x8D, 0x48, 0xFD, 0x83};
    static const uint8_t kMask7a[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};

    static const uint8_t kFind8a[] = {0x48, 0x8B, 0x86, 0x60, 0x04, 0x00, 0x00, 0x8B, 0x40, 0x0C};
    static const uint8_t kReplace8a[] = {0xB8, 0x02, 0x00, 0x00, 0x00, 0x90, 0x90, 0x90, 0x90, 0x90};
    static const uint8_t kPattern8a[] = {0x55, 0x48, 0x89, 0xE5, 0x53, 0x50, 0x89, 0xD3, 0x48, 0x89, 0xF7, 0x48, 0x8B, 0x86, 0x60, 0x04, 0x00, 0x00, 0x8B, 0x40, 0x0C, 0x8D, 0x48, 0xFF, 0x83, 0xF9, 0x02, 0x72, 0x0F, 0x8D, 0x48, 0xFD, 0x83};
    static const uint8_t kMask8a[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};

    static const uint8_t kFind9a[] = {0x8B, 0x8A, 0x84, 0x00, 0x00, 0x00, 0x8B, 0x87, 0x24, 0x04, 0x00, 0x00, 0x0F, 0xAF, 0xC1, 0x05, 0xFF, 0x00, 0x00, 0x00, 0x25, 0x00, 0xFF, 0xFF, 0xFF};
    static const uint8_t kReplace9a[] = {0x8B, 0x82, 0x80, 0x00, 0x00, 0x00, 0x8B, 0x8A, 0x84, 0x00, 0x00, 0x00, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90};
    static const uint8_t kPattern9a[] = {0x89, 0x43, 0x04, 0xC5, 0xF8, 0x57, 0xC0, 0xC5, 0xF8, 0x11, 0x43, 0x08, 0x8B, 0x8A, 0x84, 0x00, 0x00, 0x00, 0x8B, 0x87, 0x24, 0x04, 0x00, 0x00, 0x0F, 0xAF, 0xC1, 0x05, 0xFF, 0x00, 0x00, 0x00, 0x25, 0x00, 0xFF, 0xFF, 0xFF, 0x31, 0xD2, 0xF7, 0xF1, 0x89, 0x43, 0x18, 0xD1, 0xE8, 0x89, 0x43, 0x1C};
    static const uint8_t kMask9a[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};

    static const uint8_t kFind10a[] = {0xB8, 0xA4, 0x00, 0x00, 0x00};
    static const uint8_t kReplace10a[] = {0xB8, 0x30, 0x00, 0x00, 0x00};
    static const uint8_t kPattern10a[] = {0x55, 0x48, 0x89, 0xE5, 0xB8, 0xA4, 0x00, 0x00, 0x00, 0x5D, 0xC3, 0x90};
    static const uint8_t kMask10a[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};

    static const uint8_t kFind11a[] = {0x48, 0x69, 0xC0, 0xA4, 0x00, 0x00, 0x00};
    static const uint8_t kReplace11a[] = {0x48, 0x69, 0xC0, 0x30, 0x00, 0x00, 0x00};
    static const uint8_t kPattern11a[] = {0x69, 0x20, 0x4D, 0x8B, 0xB5, 0x30, 0x03, 0x00, 0x00, 0x8B, 0x40, 0x08, 0x48, 0x69, 0xC0, 0xA4, 0x00, 0x00, 0x00, 0x4C, 0x8D, 0x3C, 0x02, 0x8B, 0x44, 0x02, 0x0C, 0x3D, 0x01, 0x00, 0x00};
    static const uint8_t kMask11a[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};

    static const uint8_t kFind12a[] = {0x48, 0x69, 0xC0, 0xA4, 0x00, 0x00, 0x00};
    static const uint8_t kReplace12a[] = {0x48, 0x69, 0xC0, 0x30, 0x00, 0x00, 0x00};
    static const uint8_t kPattern12a[] = {0x69, 0x20, 0x4D, 0x8B, 0xB5, 0xB8, 0x03, 0x00, 0x00, 0x8B, 0x40, 0x08, 0x48, 0x69, 0xC0, 0xA4, 0x00, 0x00, 0x00, 0x4C, 0x8D, 0x3C, 0x02, 0x8B, 0x44, 0x02, 0x0C, 0x3D, 0x01, 0x00, 0x00};
    static const uint8_t kMask12a[] = {1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1};

    static_assert(sizeof(kFind0a) == sizeof(kReplace0a), "rule 0a: find/replace size mismatch");
    static_assert(sizeof(kFind1a) == sizeof(kReplace1a), "rule 1a: find/replace size mismatch");
    static_assert(sizeof(kFind2a) == sizeof(kReplace2a), "rule 2a: find/replace size mismatch");
    static_assert(sizeof(kFind2b) == sizeof(kReplace2b), "rule 2b: find/replace size mismatch");
    static_assert(sizeof(kFind3a) == sizeof(kReplace3a), "rule 3a: find/replace size mismatch");
    static_assert(sizeof(kFind3b) == sizeof(kReplace3b), "rule 3b: find/replace size mismatch");
    static_assert(sizeof(kFind4a) == sizeof(kReplace4a), "rule 4a: find/replace size mismatch");
    static_assert(sizeof(kFind5a) == sizeof(kReplace5a), "rule 5a: find/replace size mismatch");
    static_assert(sizeof(kFind6a) == sizeof(kReplace6a), "rule 6a: find/replace size mismatch");
    static_assert(sizeof(kFind7a) == sizeof(kReplace7a), "rule 7a: find/replace size mismatch");
    static_assert(sizeof(kFind8a) == sizeof(kReplace8a), "rule 8a: find/replace size mismatch");
    static_assert(sizeof(kFind9a) == sizeof(kReplace9a), "rule 9a: find/replace size mismatch");
    static_assert(sizeof(kFind10a) == sizeof(kReplace10a), "rule 10a: find/replace size mismatch");
    static_assert(sizeof(kFind11a) == sizeof(kReplace11a), "rule 11a: find/replace size mismatch");
    static_assert(sizeof(kFind12a) == sizeof(kReplace12a), "rule 12a: find/replace size mismatch");

    static const RuleVariant kVariant0[] = {
        {LocalKind::kPattern, 0, kPattern0a, kMask0a, static_cast<uint8_t>(sizeof(kPattern0a)), 12, kFind0a, kReplace0a, static_cast<uint8_t>(sizeof(kFind0a))},
    };

    static const RuleVariant kVariant1[] = {
        {LocalKind::kPattern, 0, kPattern1a, kMask1a, static_cast<uint8_t>(sizeof(kPattern1a)), 12, kFind1a, kReplace1a, static_cast<uint8_t>(sizeof(kFind1a))},
    };

    static const RuleVariant kVariant2[] = {
        {LocalKind::kPattern, 0, kPattern2a, kMask2a, static_cast<uint8_t>(sizeof(kPattern2a)), 12, kFind2a, kReplace2a, static_cast<uint8_t>(sizeof(kFind2a))},
        {LocalKind::kPattern, 0, kPattern2b, kMask2b, static_cast<uint8_t>(sizeof(kPattern2b)), 12, kFind2b, kReplace2b, static_cast<uint8_t>(sizeof(kFind2b))},
    };

    static const RuleVariant kVariant3[] = {
        {LocalKind::kPattern, 0, kPattern3a, kMask3a, static_cast<uint8_t>(sizeof(kPattern3a)), 12, kFind3a, kReplace3a, static_cast<uint8_t>(sizeof(kFind3a))},
        {LocalKind::kPattern, 0, kPattern3b, kMask3b, static_cast<uint8_t>(sizeof(kPattern3b)), 12, kFind3b, kReplace3b, static_cast<uint8_t>(sizeof(kFind3b))},
    };

    static const RuleVariant kVariant4[] = {
        {LocalKind::kPattern, 0, kPattern4a, kMask4a, static_cast<uint8_t>(sizeof(kPattern4a)), 12, kFind4a, kReplace4a, static_cast<uint8_t>(sizeof(kFind4a))},
    };

    static const RuleVariant kVariant5[] = {
        {LocalKind::kPattern, 0, kPattern5a, kMask5a, static_cast<uint8_t>(sizeof(kPattern5a)), 12, kFind5a, kReplace5a, static_cast<uint8_t>(sizeof(kFind5a))},
    };

    static const RuleVariant kVariant6[] = {
        {LocalKind::kPattern, 0, kPattern6a, kMask6a, static_cast<uint8_t>(sizeof(kPattern6a)), 12, kFind6a, kReplace6a, static_cast<uint8_t>(sizeof(kFind6a))},
    };

    static const RuleVariant kVariant7[] = {
        {LocalKind::kPattern, 0, kPattern7a, kMask7a, static_cast<uint8_t>(sizeof(kPattern7a)), 10, kFind7a, kReplace7a, static_cast<uint8_t>(sizeof(kFind7a))},
    };

    static const RuleVariant kVariant8[] = {
        {LocalKind::kPattern, 0, kPattern8a, kMask8a, static_cast<uint8_t>(sizeof(kPattern8a)), 11, kFind8a, kReplace8a, static_cast<uint8_t>(sizeof(kFind8a))},
    };

    static const RuleVariant kVariant9[] = {
        {LocalKind::kPattern, 0, kPattern9a, kMask9a, static_cast<uint8_t>(sizeof(kPattern9a)), 12, kFind9a, kReplace9a, static_cast<uint8_t>(sizeof(kFind9a))},
    };

    static const RuleVariant kVariant10[] = {
        {LocalKind::kPattern, 0, kPattern10a, kMask10a, static_cast<uint8_t>(sizeof(kPattern10a)), 4, kFind10a, kReplace10a, static_cast<uint8_t>(sizeof(kFind10a))},
    };

    static const RuleVariant kVariant11[] = {
        {LocalKind::kPattern, 0, kPattern11a, kMask11a, static_cast<uint8_t>(sizeof(kPattern11a)), 12, kFind11a, kReplace11a, static_cast<uint8_t>(sizeof(kFind11a))},
    };

    static const RuleVariant kVariant12[] = {
        {LocalKind::kPattern, 0, kPattern12a, kMask12a, static_cast<uint8_t>(sizeof(kPattern12a)), 12, kFind12a, kReplace12a, static_cast<uint8_t>(sizeof(kFind12a))},
    };

    const Rule kRules[] = {
        {0, ImageKind::kStandalone, "/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver", kFamilyVCN2, 0, AnchorKind::kSymbol, "_glrAMD_GFX9_UpdateHwCbDualQuadMode", nullptr, nullptr, 0, kVariant0, 1, MatchPolicy::kUnique, 0},
        {1, ImageKind::kStandalone, "/System/Library/Extensions/AMDRadeonX5000GLDriver.bundle/Contents/MacOS/AMDRadeonX5000GLDriver", kFamilyVCN2, 0, AnchorKind::kSymbol, "_gfx9_HwInfoInitData", nullptr, nullptr, 0, kVariant1, 1, MatchPolicy::kUnique, 0},
        {2, ImageKind::kSharedCache, "/System/Library/Extensions/AMDRadeonX5000MTLDriver.bundle/Contents/MacOS/AMDRadeonX5000MTLDriver", kFamilyVCN2, 0, AnchorKind::kSymbol, "-[GFX9_MtlRenderPipelineState initWithDevice:pipelineStateDescriptor:vertexVariant:fragmentVariant:]", nullptr, nullptr, 0, kVariant2, 2, MatchPolicy::kUnique, 0},
        {3, ImageKind::kSharedCache, "/System/Library/Extensions/AMDRadeonX5000MTLDriver.bundle/Contents/MacOS/AMDRadeonX5000MTLDriver", kFamilyVCN2, 0, AnchorKind::kSymbol, "-[GFX9_MtlRenderPipelineState initWithDevice:pipelineStateDescriptor:vertexVariant:fragmentVariant:]", nullptr, nullptr, 0, kVariant3, 2, MatchPolicy::kUnique, 0},
        {4, ImageKind::kSharedCache, "/System/Library/Extensions/AMDRadeonX5000MTLDriver.bundle/Contents/MacOS/AMDRadeonX5000MTLDriver", kFamilyVCN2, 0, AnchorKind::kSymbol, "__Z19gfx9_HwInfoInitDataP14GFX9_HwInfoRecP24_sAMD_GET_HW_INFO_VALUESj", nullptr, nullptr, 0, kVariant4, 1, MatchPolicy::kUnique, 0},
        {5, ImageKind::kSharedCache, "/System/Library/Extensions/AMDRadeonVADriver2.bundle/Contents/MacOS/AMDRadeonVADriver2", kFamilyVCN2, 1, AnchorKind::kSymbol, "__ZN17VAAcceleratorInfo8identifyEjj", nullptr, nullptr, 0, kVariant5, 1, MatchPolicy::kUnique, 0},
        {6, ImageKind::kSharedCache, "/System/Library/Extensions/AMDRadeonVADriver2.bundle/Contents/MacOS/AMDRadeonVADriver2", kFamilyVCN2, 1, AnchorKind::kSymbol, "__ZN9VAContext20createVideoProcessorEjjjj", nullptr, nullptr, 0, kVariant6, 1, MatchPolicy::kUnique, 0},
        {7, ImageKind::kSharedCache, "/System/Library/Extensions/AMDRadeonVADriver2.bundle/Contents/MacOS/AMDRadeonVADriver2", kFamilyVCN2, 1, AnchorKind::kSymbol, "__ZN9VAFactory20createGraphicsEngineEP9VAContext", nullptr, nullptr, 0, kVariant7, 1, MatchPolicy::kUnique, 0},
        {8, ImageKind::kSharedCache, "/System/Library/Extensions/AMDRadeonVADriver2.bundle/Contents/MacOS/AMDRadeonVADriver2", kFamilyVCN2, 1, AnchorKind::kSymbol, "__ZN9VAFactory14createImageBltEP9VAContextj", nullptr, nullptr, 0, kVariant8, 1, MatchPolicy::kUnique, 0},
        {9, ImageKind::kSharedCache, "/System/Library/Extensions/AMDRadeonVADriver2.bundle/Contents/MacOS/AMDRadeonVADriver2", kFamilyVCN2, 1, AnchorKind::kSymbol, "__ZN11Vcn2Encoder15setEncodeParamsEPvP15VAVendorTexture", nullptr, nullptr, 0, kVariant9, 1, MatchPolicy::kUnique, 0},
        {10, ImageKind::kSharedCache, "/System/Library/Extensions/AMDRadeonVADriver2.bundle/Contents/MacOS/AMDRadeonVADriver2", kFamilyVCN2, 1, AnchorKind::kSymbol, "__ZN14Vcn2EncCommand15getFeedbackSizeEv", nullptr, nullptr, 0, kVariant10, 1, MatchPolicy::kUnique, 0},
        {11, ImageKind::kSharedCache, "/System/Library/Extensions/AMDRadeonVADriver2.bundle/Contents/MacOS/AMDRadeonVADriver2", kFamilyVCN2, 1, AnchorKind::kSymbol, "__ZN26AVDVcn2AvcEncDataProcessor19ProcessEncodeStatusEP19_VAEncodeStatusInfoPvP15VAVendorTexture", nullptr, nullptr, 0, kVariant11, 1, MatchPolicy::kUnique, 0},
        {12, ImageKind::kSharedCache, "/System/Library/Extensions/AMDRadeonVADriver2.bundle/Contents/MacOS/AMDRadeonVADriver2", kFamilyVCN2, 1, AnchorKind::kSymbol, "__ZN27AVDVcn2HevcEncDataProcessor19ProcessEncodeStatusEP19_VAEncodeStatusInfoPvP15VAVendorTexture", nullptr, nullptr, 0, kVariant12, 1, MatchPolicy::kUnique, 0},
    };

    const uint32_t kRuleCount = 13;

}    // namespace NRedUserPatch
