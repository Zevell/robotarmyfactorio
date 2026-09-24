# Robot Army (forked) mod for Factorio V2.0+

A fork of the [Robot Army mod](https://github.com/kyranf/robotarmyfactorio) by Kyranzor, with bugfixes, extra settings and automatic migration of existing saves. Free for anyone to use. See [Changes in this fork](#changes-in-this-fork) below.

## Factorio Version
Known to be compatible with Factorio v2.0.60. Requires at least v2.0 due to mod script API features used.


## Description
A mod to add robot troop units and associated support buildings and items to produce and control them. Will allow the users to automate warfare against the Biters or other players if you are using a PvP scenario.

Note the Unit Control mod works very well for controlling the Robot Army units and when active will disable normal automated squad control (to make it work smoother)

The original mod's content is documented [on its GitHub Wiki page](https://github.com/kyranf/robotarmyfactorio/wiki); the fork does not change any gameplay content, so it applies here as well.

The Factorio Forums thread for the original mod can be found here: [Forum link](https://forums.factorio.com/viewtopic.php?f=97&t=23543)

Mod portal link for the original mod: [Mod Portal](https://mods.factorio.com/mods/kyranzor/robotarmy)

## Credits
* YuokiTani for the great models of the Droids
* Klonan for his Combat Units and permission to integrate the mod into mine, and his great work with the Unit Control mods
* Dauphin for his significant contributions to the codebase for squad AI and performance enhancements
* Earendel for inspiration and code examples for the RTS-style control of units from the AAI Programmable Vehicles mod.
* Felipe Bueno Aliski Alves for the Brazilian Portuguese translations
* Varoga for the russian translations
* cyril-orlov for the Factorio v2.0 migration work

## Changes in this fork
This repository is a fork of Robot Army by Kyranzor. Differences from the original:
- Fixes the invalid commandable crash when droids die during Quick Reaction Force responses
- Adds a setting to toggle the QRF destruction alert message
- Adds a setting to toggle the squad destroyed message
- Adds an optional strict squad size rule for QRF responses
- Existing saves from the original mod migrate automatically: droid assemblers, guard stations and other mod buildings are re-registered, deployed droids are re-adopted into squads and consolidated back up to strength, and recipes unlocked by your research are re-enabled - so it works as a drop-in replacement

See changelog.txt for the full per-version history of this fork.

## Donations
If you are feeling generous or thankful for the mod, feel free to donate to the original author, Kyranzor, so he can bribe his wife with chocolate to help her put up with his late nights! Click the image below:
[![](https://www.paypalobjects.com/en_US/i/btn/btn_donateCC_LG.gif)](https://www.paypal.me/KyranF)
Or simply use this: [Donate](https://www.paypal.me/KyranF)