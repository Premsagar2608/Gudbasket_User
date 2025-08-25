import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  final user = FirebaseAuth.instance.currentUser;
  final dbRef = FirebaseDatabase.instance.ref();
  Map<String, dynamic> userOrders = {};

  @override
  void initState() {
    super.initState();
    if (user != null) {
      fetchUserOrders();
    }
  }

  Future<void> fetchUserOrders() async {
    final snapshot = await dbRef.child("users/${user!.uid}/orders").get();
    if (snapshot.exists) {
      setState(() {
        userOrders = Map<String, dynamic>.from(snapshot.value as Map);
      });
    }
  }

  Future<void> attachLocationToOrder(String city, String shopId, String orderId) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text("Fetching location..."),
          ],
        ),
      ),
    );

    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) throw Exception("Location services are disabled.");

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) throw Exception("Location permission denied");
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception("Location permission permanently denied");
      }

      Position pos = await Geolocator.getCurrentPosition();
      List<Placemark> placemarks = await placemarkFromCoordinates(pos.latitude, pos.longitude);

      if (placemarks.isNotEmpty) {
        final placemark = placemarks.first;
        String formattedAddress =
            "${placemark.street}, ${placemark.subLocality}, ${placemark.locality}, ${placemark.postalCode}";

        DatabaseReference shopOrderRef = dbRef.child("cities/$city/shops/$shopId/orders/$orderId");

        await shopOrderRef.update({
          "address": formattedAddress,
          "location": {
            "lat": pos.latitude,
            "lng": pos.longitude,
          }
        });
      }

      Navigator.pop(context); // close dialog
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Location saved to shop's order")),
      );
    } catch (e) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Location error: $e")));
    }
  }

  Color getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case "delivered":
        return Colors.green;
      case "dispatched":
        return Colors.blue;
      case "accepted":
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Your Orders")),
      body: user == null
          ? const Center(child: Text("Please login to view orders"))
          : userOrders.isEmpty
          ? const Center(child: Text("No orders found"))
          : ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: userOrders.length,
        itemBuilder: (context, index) {
          final entry = userOrders.entries.elementAt(index);
          final orderId = entry.key;
          final order = Map<String, dynamic>.from(entry.value);
          final status = order["status"] ?? "ordered";
          final total = order["total"] ?? 0;
          final address = order["address"] ?? "N/A";
          final city = order["city"] ?? "unknown";
          final shopId = order["shopId"] ?? "unknown";
          final timestamp = order["timestamp"];
          final items = List<Map>.from(order["items"] ?? []);

          String dateFormatted = "N/A";
          if (timestamp != null) {
            try {
              final date = DateTime.parse(timestamp);
              dateFormatted =
              "${date.day}-${date.month}-${date.year} ${date.hour}:${date.minute}";
            } catch (_) {}
          }

          return Card(
            elevation: 3,
            margin: const EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Chip(
                        label: Text(
                          status.toUpperCase(),
                          style: const TextStyle(color: Colors.white),
                        ),
                        backgroundColor: getStatusColor(status),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text("Address: $address"),
                  Text("Total: ₹$total"),
                  const SizedBox(height: 10),
                  const Text(
                    "Items:",
                    style: TextStyle(
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                  ...items.map((item) {
                    final name = item['name'] ?? 'Unnamed';
                    final qty = item['quantity'] ?? 1;
                    return Text("• $name x$qty");
                  }),
                  const SizedBox(height: 10),
                  Text(
                    "Placed on: $dateFormatted",
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    onPressed: () {
                      attachLocationToOrder(city, shopId, orderId);
                    },
                    icon: const Icon(Icons.location_on),
                    label: const Text("Attach GPS Location"),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
