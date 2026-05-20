{
	resource(settings): {
		aws_wafv2_ip_set: {
			npk_allowlist: {
				provider: "aws.us-east-1",
				name: "npk-allowed-source-ips",
				description: "Source IPs allowed to access NPK CloudFront",
				scope: "CLOUDFRONT",
				ip_address_version: "IPV4",
				addresses: settings.allowedSourceIps,
			}
		},
		aws_wafv2_web_acl: {
			npk: {
				provider: "aws.us-east-1",
				name: "npk-cloudfront-acl",
				description: "NPK CloudFront source IP allowlist",
				scope: "CLOUDFRONT",
				default_action: {
					block: {},
				},
				rule: [{
					name: "allow-source-ips",
					priority: 1,
					action: {
						allow: {},
					},
					statement: {
						ip_set_reference_statement: {
							arn: "${aws_wafv2_ip_set.npk_allowlist.arn}",
						},
					},
					visibility_config: {
						cloudwatch_metrics_enabled: true,
						metric_name: "npk-allow-source-ips",
						sampled_requests_enabled: true,
					},
				}],
				visibility_config: {
					cloudwatch_metrics_enabled: true,
					metric_name: "npk-cloudfront-acl",
					sampled_requests_enabled: true,
				},
			}
		}
	}
}
