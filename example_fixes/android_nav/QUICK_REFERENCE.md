# Quick Reference - Navigation Architecture

## Screen Organization (16 Total)

```
┌─────────────────────────────────────────┐
│         LOGIN SCREEN (1)                │
│  - Entry point for all users            │
│  - Routes to operator or pilot role     │
└─────────────────┬───────────────────────┘
                  │
        ┌─────────┴──────────┐
        │                    │
   ┌────▼────────┐      ┌────▼────────┐
   │  OPERATOR   │      │   PILOT     │
   │  (9 screens)│      │ (6 screens) │
   └────┬────────┘      └────┬────────┘
        │                    │
    Dashboard             MyFlights
    Requests List         Flight Detail
    Request Detail        Flight En Route
    Publish Slot          Flight Landed
    Fleet                 Settings
    Aircraft Detail
    Live Flights
    Flight Notes
    Settings
```

## Route Constants Structure

```kotlin
object Route {
    // Authentication (1)
    const val LOGIN = "login"
    
    // Operator Navigation Host (1)
    const val OPERATOR_NAV_HOST = "operator_nav_host"
    
    // Operator Screens (9)
    const val DASHBOARD = "dashboard"
    const val REQUESTS_LIST = "requests_list"
    const val REQUEST_DETAIL = "request_detail/{requestId}"
    const val PUBLISH_SLOT = "publish_slot"
    const val FLEET = "fleet"
    const val AIRCRAFT_DETAIL = "aircraft_detail/{aircraftId}"
    const val LIVE_FLIGHTS = "live_flights"
    const val FLIGHT_NOTES = "flight_notes/{flightId}"
    const val OPERATOR_SETTINGS = "operator_settings"
    
    // Pilot Navigation Host (1)
    const val PILOT_NAV_HOST = "pilot_nav_host"
    
    // Pilot Screens (6)
    const val MY_FLIGHTS = "my_flights"
    const val FLIGHT_DETAIL = "flight_detail/{flightId}"
    const val FLIGHT_EN_ROUTE = "flight_en_route/{flightId}"
    const val FLIGHT_LANDED = "flight_landed/{flightId}"
    const val PILOT_SETTINGS = "pilot_settings"
}
```

## Navigation Flow Diagram

```
START
  │
  ├─→ LoginScreen
  │     ├─→ [Operator Login]
  │     │     ├─→ popUpTo(LOGIN)
  │     │     └─→ navigate(OPERATOR_NAV_HOST)
  │     │
  │     └─→ [Pilot Login]
  │           ├─→ popUpTo(LOGIN)
  │           └─→ navigate(PILOT_NAV_HOST)
  │
  ├─→ OperatorNavGraph (nested)
  │     ├─→ Dashboard
  │     │     ├─→ Requests List
  │     │     │     ├─→ Request Detail
  │     │     │           └─→ Publish Slot
  │     │     │
  │     │     ├─→ Fleet
  │     │     │     └─→ Aircraft Detail
  │     │     │
  │     │     └─→ Settings
  │     │
  │     └─→ Live Flights
  │           └─→ Flight Notes
  │
  └─→ PilotNavGraph (nested)
        ├─→ My Flights
        │     └─→ Flight Detail
        │           ├─→ Start → Flight En Route
        │           │              └─→ Land → Flight Landed
        │           │                           └─→ My Flights
        │           └─→ Cancel
        │
        └─→ Settings
```

## Key Navigation Patterns

### 1. Simple Navigation (No Arguments)
```kotlin
composable(Route.DASHBOARD) {
    DashboardScreen(
        onNavigate = { navController.navigate(Route.REQUESTS_LIST) }
    )
}
```

### 2. Navigation with Arguments
```kotlin
composable(Route.REQUEST_DETAIL) { backStackEntry ->
    val requestId = backStackEntry.arguments?.getString("requestId") ?: ""
    RequestDetailScreen(requestId = requestId)
}
```

### 3. Argument Builder Helper
```kotlin
// In Route.kt
fun requestDetail(requestId: String) = "request_detail/$requestId"

// In NavigationCallback
onRequestSelected = { requestId ->
    navController.navigate(Route.requestDetail(requestId))
}
```

### 4. Back Stack Management
```kotlin
// Remove entire stack
navController.navigate(Route.NEXT_SCREEN) {
    popUpTo(Route.CURRENT_SCREEN) { inclusive = true }
}

// Keep some screens in back stack
navController.navigate(Route.NEXT_SCREEN) {
    popUpTo(Route.ANCHOR_SCREEN) { inclusive = false }
}
```

## Common Crash Scenarios (Now Fixed)

| Issue | Cause | Fix |
|-------|-------|-----|
| Route not found | Undefined constant | All 16 constants defined in Route.kt |
| NullPointerException | Argument not extracted | Use `backStackEntry.arguments?.getString()` |
| Screen not rendered | Missing composable | All 15 screens implemented |
| Nav graph empty | Stub implementation | operatorNavGraph & pilotNavGraph complete |
| Can't navigate back | Incorrect back stack | Proper `popUpTo()` usage |

## File Checklist

- ✅ `Route.kt` - 16 route constants
- ✅ `NavGraphs.kt` - RootNavHost, operatorNavGraph, pilotNavGraph
- ✅ `ScreenImplementations.kt` - All 15 screen composables
- ✅ `MainActivity.kt` - Proper NavController setup
- ✅ Build configuration - compiles without errors
- ✅ Testing - app launches without crashing

## Testing Commands

```bash
# Build and install on device/emulator
./gradlew installDebug

# Run app
adb shell am start -n com.skyrik.ops/.MainActivity

# Check logs for crashes
adb logcat | grep FATAL
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| App crashes on launch | Check LogCat for NullPointerException, verify all routes defined |
| Screen not found | Verify composable is in correct NavGraph |
| Arguments lost | Ensure route constants use {argName} placeholder |
| Can't navigate back | Check popUpTo logic in navigation callbacks |
| Compilation error | Verify all imports, check NavGraphBuilder scope |

---
**Generated:** 2026-04-13
**Version:** 1.0
**Status:** ✅ Ready for implementation
