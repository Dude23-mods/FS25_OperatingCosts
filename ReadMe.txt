FS25_OperatingCosts / Realistic Operating Costs
Version: 1.0.0.0
Author: Dude23

Description
-----------
Realistic Operating Costs adds monthly operating costs for vehicles, implements, buildings and stored goods. Costs are calculated automatically on period/month change and shown as a short in-game notification. When the savegame is saved, the mod writes operatingCostsHistory.xml to the savegame folder. An in-game overview window can display saved costs by category and period. The mod also shows preview values for expected monthly costs in the vehicle shop and construction menu.

Scope
-----
The mod does not add land transfer tax or property tax. Land-related taxes are not part of this mod, so the focus stays on operating costs, insurance and upkeep.

Cost types
----------

1. Vehicle and equipment insurance
- Self-propelled vehicles pay a monthly rate based on the new or purchase value and the game's economy difficulty.
- Trailers and implements pay a reduced rate.
- Vehicle and equipment insurance is booked to vehicleRunningCost / vehicle running costs.
- Leased vehicles are not charged additionally.
- Consumable and storage objects that technically appear in the vehicle system, such as pallets, big bags and bales, are not treated as insurable vehicles or implements.

2. Building upkeep / upkeep difference
- For owned buildings and placeables, a target upkeep is calculated from the construction price.
- Existing upkeep from the base game or another mod is taken into account.
- Only the difference is charged if the target value is higher than the existing upkeep.
- If the existing upkeep is already higher, nothing is charged.
- These costs are booked to propertyMaintenance / property maintenance.
- Pre-placed farm buildings without usable price data use conservative internal fallback values.

3. Stored goods insurance
- Stored goods are insured based on their estimated goods value.
- Stored goods insurance is booked to other / miscellaneous because the base game has no more suitable standard category.
- Storage detection is defensive and uses known storage structures as well as direct silo functions. Very custom storages from maps or building mods may not be detected completely.

Default rates
-------------
The default rates are monthly values and can be adjusted per savegame in operatingCostsConfig.xml.

Vehicle insurance:
- Easy: 0.10 %
- Medium: 0.20 %
- Hard: 0.30 %

Implement/trailer insurance:
- Easy: 0.05 %
- Medium: 0.10 %
- Hard: 0.15 %

Building upkeep:
- Easy: 0.10 %
- Medium: 0.20 %
- Hard: 0.30 %

Stored goods insurance:
- Easy: 0.025 %
- Medium: 0.050 %
- Hard: 0.075 %

Operating costs overview
------------------------
- The window is opened and closed with CTRL + ALT + B by default.
- The key combination can be changed in the control settings using the entry “Overview Menu”.
- The window is not an ESC menu page. It is drawn directly as an in-game overlay window.
- When opened, the mouse cursor is shown. The window can also be closed with ESC.
- The top bar contains tabs for Total, Vehicle/equipment insurance, Stored goods insurance and Upkeep.
- The period filter can switch between Month, Year and All years.
- Month view shows individual entries from operatingCostsHistory.xml or from the current in-memory evaluation before the savegame is saved.
- Year view summarizes monthly values.
- All years summarizes saved years so year 1 and year 2 can be compared directly.
- Long individual entry lists are shown with a scrollbar.
- A bottom total row is shown.
- The current farm name is used where possible.

Vehicle shop and construction menu preview
------------------------------------------
- The vehicle shop shows the expected monthly vehicle/equipment insurance.
- The construction menu shows the expected monthly building upkeep.
- The preview shows the assessment value, detected category and economy difficulty.
- In the construction menu, existing upkeep and additional upkeep are shown separately.
- Additional upkeep only shows the difference between target upkeep and already existing upkeep.

Finance overview
----------------
The mod does not register custom MoneyTypes. It uses existing base-game finance categories:
- Buildings/silos/upkeep: propertyMaintenance
- Vehicles/equipment/trailers: vehicleRunningCost
- Stored goods insurance: other

Additional detail file
----------------------
When the savegame is saved, the mod creates or updates operatingCostsHistory.xml in the savegame folder. The file lists individual entries with object name, amount, assessment value, rate and finance category. It is read again when the savegame loads and when the overview window is opened, so a real history across several saved months and years can be displayed. Duplicate records for the same farm, year and month are prevented or cleaned up.

Savegame configuration
----------------------
When saving, the mod creates operatingCostsConfig.xml in the savegame folder if the file does not exist yet. This file can be used to adjust the monthly percentages. Values are percentage values, not decimal factors. Example: 0.30 means 0.30 % per month.

The following values can be adjusted for each economy difficulty:
- motorVehicleInsurancePercent: insurance for self-propelled vehicles
- implementInsurancePercent: insurance for implements and trailers
- placeableUpkeepPercent: target upkeep for buildings/placeables
- storedGoodsInsurancePercent: stored goods insurance

After changing the file, reload the savegame to make sure the new values are applied.

Multiplayer
-----------
The calculation runs only on the server/host. This should prevent duplicate client-side charges. In multiplayer, the notification is sent to the affected farm. The overview window reads the locally available operatingCostsHistory.xml of the savegame.

Known limitations
-----------------
- The window is a drawn in-game overlay window, not a fully integrated ESC menu screen.
- Static map buildings without shop item or saved price data cannot be valued fully realistically.
- Very custom storages from maps or building mods may not be detected completely.
- The default values are intended as a gameplay basis and can be adjusted per savegame.
