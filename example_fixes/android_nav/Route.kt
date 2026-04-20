/**
 * Navigation route constants for the Skyrik Ops Android app.
 * Defines all 16 screen routes organized by role: Login, Operator, and Pilot.
 */

object Route {
    // Authentication
    const val LOGIN = "login"
    
    // Operator Navigation Host
    const val OPERATOR_NAV_HOST = "operator_nav_host"
    
    // Operator Screens (8 total)
    const val DASHBOARD = "dashboard"
    const val REQUESTS_LIST = "requests_list"
    const val REQUEST_DETAIL = "request_detail/{requestId}"
    const val PUBLISH_SLOT = "publish_slot"
    const val FLEET = "fleet"
    const val AIRCRAFT_DETAIL = "aircraft_detail/{aircraftId}"
    const val LIVE_FLIGHTS = "live_flights"
    const val FLIGHT_NOTES = "flight_notes/{flightId}"
    const val OPERATOR_SETTINGS = "operator_settings"
    
    // Pilot Navigation Host
    const val PILOT_NAV_HOST = "pilot_nav_host"
    
    // Pilot Screens (7 total)
    const val MY_FLIGHTS = "my_flights"
    const val FLIGHT_DETAIL = "flight_detail/{flightId}"
    const val FLIGHT_EN_ROUTE = "flight_en_route/{flightId}"
    const val FLIGHT_LANDED = "flight_landed/{flightId}"
    const val PILOT_SETTINGS = "pilot_settings"
    
    // Route builders with arguments
    fun requestDetail(requestId: String) = "request_detail/$requestId"
    fun aircraftDetail(aircraftId: String) = "aircraft_detail/$aircraftId"
    fun flightNotes(flightId: String) = "flight_notes/$flightId"
    fun flightDetail(flightId: String) = "flight_detail/$flightId"
    fun flightEnRoute(flightId: String) = "flight_en_route/$flightId"
    fun flightLanded(flightId: String) = "flight_landed/$flightId"
}
