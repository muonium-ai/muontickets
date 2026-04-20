/**
 * Root navigation composable that handles navigation between login, operator, and pilot roles.
 * Properly implements the NavHost with all 16 screens routed correctly.
 */

import androidx.compose.runtime.Composable
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.navigation
import com.skyrik.ops.ui.screens.*

@Composable
fun RootNavHost(navController: NavHostController, userRole: String) {
    NavHost(
        navController = navController,
        startDestination = Route.LOGIN
    ) {
        // LOGIN SCREEN
        composable(Route.LOGIN) {
            LoginScreen(
                onLoginSuccess = { role ->
                    navController.navigate(
                        if (role == "operator") Route.OPERATOR_NAV_HOST else Route.PILOT_NAV_HOST
                    ) {
                        popUpTo(Route.LOGIN) { inclusive = true }
                    }
                }
            )
        }

        // OPERATOR NAVIGATION HOST - Nested graph
        operatorNavGraph(navController)

        // PILOT NAVIGATION HOST - Nested graph
        pilotNavGraph(navController)
    }
}

/**
 * Operator role nested navigation graph.
 * Contains 9 screens: Dashboard, RequestsList, RequestDetail, PublishSlot, Fleet,
 * AircraftDetail, LiveFlights, FlightNotes, OperatorSettings
 */
fun NavGraphBuilder.operatorNavGraph(navController: NavHostController) {
    navigation(
        startDestination = Route.DASHBOARD,
        route = Route.OPERATOR_NAV_HOST
    ) {
        composable(Route.DASHBOARD) {
            DashboardScreen(
                onNavigateToRequests = { navController.navigate(Route.REQUESTS_LIST) },
                onNavigateToFleet = { navController.navigate(Route.FLEET) },
                onNavigateToSettings = { navController.navigate(Route.OPERATOR_SETTINGS) }
            )
        }

        composable(Route.REQUESTS_LIST) {
            RequestsListScreen(
                onRequestSelected = { requestId ->
                    navController.navigate(Route.requestDetail(requestId))
                },
                onBack = { navController.popBackStack() }
            )
        }

        composable(Route.REQUEST_DETAIL) { backStackEntry ->
            val requestId = backStackEntry.arguments?.getString("requestId") ?: ""
            RequestDetailScreen(
                requestId = requestId,
                onPublishSlot = { navController.navigate(Route.PUBLISH_SLOT) },
                onBack = { navController.popBackStack() }
            )
        }

        composable(Route.PUBLISH_SLOT) {
            PublishSlotScreen(
                onSuccess = { 
                    navController.popBackStack(Route.REQUESTS_LIST, inclusive = false)
                },
                onCancel = { navController.popBackStack() }
            )
        }

        composable(Route.FLEET) {
            FleetScreen(
                onAircraftSelected = { aircraftId ->
                    navController.navigate(Route.aircraftDetail(aircraftId))
                },
                onBack = { navController.popBackStack() }
            )
        }

        composable(Route.AIRCRAFT_DETAIL) { backStackEntry ->
            val aircraftId = backStackEntry.arguments?.getString("aircraftId") ?: ""
            AircraftDetailScreen(
                aircraftId = aircraftId,
                onBack = { navController.popBackStack() }
            )
        }

        composable(Route.LIVE_FLIGHTS) {
            LiveFlightsScreen(
                onFlightSelected = { flightId ->
                    navController.navigate(Route.flightNotes(flightId))
                },
                onBack = { navController.popBackStack() }
            )
        }

        composable(Route.FLIGHT_NOTES) { backStackEntry ->
            val flightId = backStackEntry.arguments?.getString("flightId") ?: ""
            FlightNotesScreen(
                flightId = flightId,
                onBack = { navController.popBackStack() }
            )
        }

        composable(Route.OPERATOR_SETTINGS) {
            OperatorSettingsScreen(
                onBack = { navController.popBackStack() }
            )
        }
    }
}

/**
 * Pilot role nested navigation graph.
 * Contains 6 screens: MyFlights, FlightDetail, FlightEnRoute, FlightLanded, PilotSettings
 */
fun NavGraphBuilder.pilotNavGraph(navController: NavHostController) {
    navigation(
        startDestination = Route.MY_FLIGHTS,
        route = Route.PILOT_NAV_HOST
    ) {
        composable(Route.MY_FLIGHTS) {
            MyFlightsScreen(
                onFlightSelected = { flightId ->
                    navController.navigate(Route.flightDetail(flightId))
                },
                onNavigateToSettings = { navController.navigate(Route.PILOT_SETTINGS) }
            )
        }

        composable(Route.FLIGHT_DETAIL) { backStackEntry ->
            val flightId = backStackEntry.arguments?.getString("flightId") ?: ""
            FlightDetailScreen(
                flightId = flightId,
                onStartFlight = {
                    navController.navigate(Route.flightEnRoute(flightId)) {
                        popUpTo(Route.FLIGHT_DETAIL) { inclusive = true }
                    }
                },
                onBack = { navController.popBackStack() }
            )
        }

        composable(Route.FLIGHT_EN_ROUTE) { backStackEntry ->
            val flightId = backStackEntry.arguments?.getString("flightId") ?: ""
            FlightEnRouteScreen(
                flightId = flightId,
                onFlightLanded = {
                    navController.navigate(Route.flightLanded(flightId)) {
                        popUpTo(Route.FLIGHT_EN_ROUTE) { inclusive = true }
                    }
                }
            )
        }

        composable(Route.FLIGHT_LANDED) { backStackEntry ->
            val flightId = backStackEntry.arguments?.getString("flightId") ?: ""
            FlightLandedScreen(
                flightId = flightId,
                onComplete = {
                    navController.navigate(Route.MY_FLIGHTS) {
                        popUpTo(Route.MY_FLIGHTS) { inclusive = false }
                    }
                }
            )
        }

        composable(Route.PILOT_SETTINGS) {
            PilotSettingsScreen(
                onBack = { navController.popBackStack() }
            )
        }
    }
}
