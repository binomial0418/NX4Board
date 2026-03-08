import 'package:flutter/material.dart';

class StatusDisplay extends StatelessWidget {
  final String status;

  const StatusDisplay({Key? key, required this.status}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    Color statusColor = Colors.blue;
    IconData statusIcon = Icons.info;

    if (status.contains('Initializing')) {
      statusColor = Colors.orange;
      statusIcon = Icons.hourglass_empty;
    } else if (status.contains('No sign')) {
      statusColor = Colors.grey;
      statusIcon = Icons.location_off;
    } else if (status.contains('detected')) {
      statusColor = Colors.green;
      statusIcon = Icons.check_circle;
    } else if (status.contains('Error') || status.contains('error')) {
      statusColor = Colors.red;
      statusIcon = Icons.error;
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.1),
        border: Border.all(color: statusColor, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              status,
              style: TextStyle(
                color: statusColor,
                fontWeight: FontWeight.w500,
                fontSize: 14,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
