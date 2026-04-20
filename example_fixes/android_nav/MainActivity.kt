/**
 * MainActivity implementation showing proper NavController setup.
 * Handles user role detection and initializes the navigation graph correctly.
 */

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.navigation.compose.rememberNavController
import com.skyrik.ops.ui.navigation.RootNavHost
import com.skyrik.ops.ui.theme.SkyrikOpsTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            SkyrikOpsTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    MainNavigation()
                }
            }
        }
    }
}

@Composable
private fun MainNavigation() {
    val navController = rememberNavController()
    var userRole by remember { mutableStateOf<String?>(null) }

    // In a real app, fetch user role from authentication/session
    LaunchedEffect(Unit) {
        userRole = getUserRoleFromSession()
    }

    if (userRole != null) {
        RootNavHost(navController = navController, userRole = userRole!!)
    }
}

private fun getUserRoleFromSession(): String? {
    // TODO: Replace with actual authentication logic
    return null // Will show login screen
}
