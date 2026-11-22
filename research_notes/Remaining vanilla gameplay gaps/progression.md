# Item and pet progression

## Which crafting behavior is absent?

### Takeaway
Newly crafted eligible items lose their maker's signature at creation.

### Cited findings
- The original 1.12.1 client has a dedicated green “Made by” tooltip entry; the installed 1.12.1 executable also contains the ITEM_CREATED_BY key. The reference Classic emulator sets ITEM_FIELD_CREATOR on successfully crafted eligible items. Our create-item spell calls giveItem, which stores the item and sends the creation notification without assigning its maker. The inventory can already serialize a supplied creator. Real world data includes Brown Linen Robe (7623 → item 6238) and Handstitched Leather Belt (3753 → item 4237). [Original client UI](https://github.com/tekkub/wow-ui-source/blob/1.12.1/FrameXML/GlobalStrings.lua#L2400) · [CMaNGOS corroboration](https://github.com/cmangos/mangos-classic/blob/master/src/game/Spells/SpellEffects.cpp#L1867) · [create-item effect](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/spelleffects.d#L471) · [grant path](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/gmactions.d#L155) · [existing creator field](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/inventory.d#L390).

### Inferences
- Test a tailor crafting one Brown Linen Robe. Inspect the maker name as the tailor, trade it to a different character, and inspect it again after relog. Exclude ordinary loot and vendor purchases from maker assignment.

### Gaps
- Determine the exact eligible item classes before a fix; a crafting spell also creates consumables, and this audit does not establish that every output should be signed.

## What is missing in hunter pet training?

### Takeaway
The server checks level and training points but omits the four-active-ability limit. The visible action bar already has four spell slots.

### Cited findings
- The original client includes a dedicated failure message for a pet that has learned too many skills, and Wowhead Classic documents four active abilities per pet. The validator only checks pet, spell, level and training-point cost. PetState.learn appends to the persistent list before trying to add the spell to the bar; a full bar does not roll back that append. [Original UI error](https://github.com/tekkub/wow-ui-source/blob/1.12.1/FrameXML/GlobalStrings.lua#L4072) · [Wowhead Classic hunter pet guide](https://www.wowhead.com/classic/guide/classic-wow-hunter-pets) · [server cast check](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/pethandlers.d#L734) · [learned-spell insertion](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/pet.d#L260) · [action bar](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/pet.d#L147).
- The same path lacks a pet-family eligibility check. Petopia documents family-specific training (for example Charge for boars). The original UI can filter the recipes it offers. Treat this as a **server validation gap** with normal-UI impact unverified. [Classic family ability tables](https://www.wow-petopia.com/classic/abilities.php#charge) · [validator](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/pethandlers.d#L734).

### Inferences
- Test a qualified cat with Growl, Bite, Claw and Dash already trained. Attempt to add Prowl as its fifth independent active skill, verify points/known spells stay unchanged, then verify that an upgrade to an existing rank and a passive ability still work. [Family and level table](https://www.wow-petopia.com/classic/abilities.php).

### Gaps
- These are source findings. There was no scripted or live test of the client training window in this pass.

## Which gathering paths were checked?

### Takeaway
There is concrete implementation and test coverage for gathering checks. I did not establish a separate gathering-system omission.

### Cited findings
- The gathering interaction validates skill before looting. Tests include a thorium vein failing below the mining threshold, and herbalism loot, skill gains and repeated opens. Fishing schools have a live spell target path. [Mining and herbalism tests](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/gameobjecthandlers.d#L820) · [gathering tests](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/gameobjecthandlers.d#L837) · [fishing schools](https://github.com/hamros1/vibemangos/blob/780ff1948f923d735e4abef929b4d026e9278fee/source/dmangos/world/spellhandlers.d#L1322).

### Inferences
- Existing evidence supports investigating individual remaining mechanics and fixtures, rather than listing gathering or pet training wholesale as unimplemented.

### Gaps
- No exhaustive comparison of zone spawn distributions, rare loot probabilities or all recipe sources.
